/*
 * Filename: backend_pdf.m
 * Project: Appine (App in Emacs)
 * Description: Emacs dynamic module to embed native macOS views
 *              (WebKit, PDFKit, Quick Look, etc.) directly inside Emacs windows.
 * Author: Chao Huang <huangchao.cpp@gmail.com>
 * Copyright (C) 2026, Chao Huang, all rights reserved.
 * URL: https://github.com/chaoswork/appine
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <https://www.gnu.org/licenses/>.
 */
#import "appine_backend.h"
#import "appine_core.h"
#import <PDFKit/PDFKit.h>

@interface AppinePdfBackend : NSObject <AppineBackend, NSTextFieldDelegate, NSSearchFieldDelegate, NSGestureRecognizerDelegate, NSOutlineViewDataSource, NSOutlineViewDelegate, NSTableViewDataSource, NSTableViewDelegate, PDFDocumentDelegate>


@property (nonatomic, strong) NSView *containerView;
@property (nonatomic, strong) PDFView *pdfView;
@property (nonatomic, copy) NSString *path;

// --- 左侧固定工具栏与侧边栏面板 ---
@property (nonatomic, strong) NSView *leftToolBar;
@property (nonatomic, strong) NSButton *searchBtn;
@property (nonatomic, strong) NSButton *outlineBtn;

@property (nonatomic, strong) NSView *sidePanelView;
@property (nonatomic, assign) NSInteger currentSidePanelMode; // 0: 隐藏, 1: 大纲, 2: 搜索

// ---- Outline 相关属性 ----
@property (nonatomic, strong) NSScrollView *outlineScrollView;
@property (nonatomic, strong) NSOutlineView *outlineView;

// ---- search view 相关属性 ----
@property (nonatomic, strong) NSView *searchPanelView;
@property (nonatomic, strong) NSSearchField *sideSearchField;
@property (nonatomic, strong) NSScrollView *searchResultsScrollView;
@property (nonatomic, strong) NSTableView *searchResultsTableView;
@property (nonatomic, strong) NSMutableArray<PDFSelection *> *searchResults;
@property (nonatomic, assign) NSInteger currentMatchIndex;

// ---- highlight/comment
@property (nonatomic, strong) NSView *primaryMenu;
@property (nonatomic, strong) NSView *highlightMenu;
@property (nonatomic, strong) NSView *commentMenu;
@property (nonatomic, strong) NSTextField *commentTextField;
@property (nonatomic, strong) PDFAnnotation *currentAnnotation;
@property (nonatomic, strong) NSTimer *highlightMenuTimer;

@property (nonatomic, strong) NSView *saveBarView;
@property (nonatomic, assign) BOOL isModified;
@property (nonatomic, assign) BOOL isSavePositionEnabled;
@property (nonatomic, strong) id eventMonitor;
@property (nonatomic, strong) id clickMonitor;

- (void)toggleFindBar; // 供 appine_core 调用

@end

@implementation AppinePdfBackend

- (AppineBackendKind)kind {
    return AppineBackendKindPDF;
}

- (instancetype)initWithPath:(NSString *)path {
    self = [super init];
    if (self) {
        _path = [path copy];
        _currentMatchIndex = -1;
        _searchResults = [NSMutableArray array];

        [self setupUI];

        if (_path && _path.length > 0) {
            NSURL *url = [NSURL fileURLWithPath:_path];
            if (url) {
                PDFDocument *doc = [[PDFDocument alloc] initWithURL:url];
                if (doc) {
                    doc.delegate = self;
                    _isSavePositionEnabled = NO; // 加载期间禁止保存，防止覆盖存档
                    [_pdfView setDocument:doc];
                    // 如果没有大纲，隐藏 Sidebar 按钮
                    if (!doc.outlineRoot) {
                        _outlineBtn.enabled = NO;
                    } else {
                        // 默认展开所有大纲节点
                        [_outlineView reloadData];
                        [_outlineView expandItem:nil expandChildren:YES];
                    }
                    // 恢复上次阅读位置
                    [self restoreLastPosition];
                }
            }
        }
    }
    return self;
}

- (void)setupUI {
    // 1. 创建主容器
    _containerView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 800, 600)];
    _containerView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

    CGFloat toolBarWidth = 40.0;
    CGFloat sidePanelWidth = 250.0;

    // ================= 左侧固定工具栏 =================
    _leftToolBar = appine_create_color_box(NSMakeRect(0, 0, toolBarWidth, _containerView.bounds.size.height), [NSColor windowBackgroundColor], NSViewHeightSizable | NSViewMaxXMargin);
    // 右侧分割线
    NSBox *border = appine_create_color_box(NSMakeRect(toolBarWidth - 1, 0, 1, _containerView.bounds.size.height), [NSColor separatorColor], NSViewHeightSizable | NSViewMinXMargin);

    [((NSBox *)_leftToolBar).contentView addSubview:border];

    // 搜索按钮 (使用 SF Symbols)
    _searchBtn = [NSButton buttonWithImage:[NSImage imageWithSystemSymbolName:@"magnifyingglass" accessibilityDescription:nil] target:self action:@selector(toggleSearchPanel)];
    _searchBtn.frame = NSMakeRect(4, _containerView.bounds.size.height - 40, 32, 32);
    _searchBtn.autoresizingMask = NSViewMinYMargin;
    _searchBtn.bordered = NO;
    _searchBtn.contentTintColor = [NSColor labelColor];
    [((NSBox *)_leftToolBar).contentView addSubview:_searchBtn];


    // 大纲按钮 (使用 SF Symbols)
    _outlineBtn = [NSButton buttonWithImage:[NSImage imageWithSystemSymbolName:@"list.bullet" accessibilityDescription:nil] target:self action:@selector(toggleOutlinePanel)];
    _outlineBtn.frame = NSMakeRect(4, _containerView.bounds.size.height - 80, 32, 32);
    _outlineBtn.autoresizingMask = NSViewMinYMargin;
    _outlineBtn.bordered = NO;
    _outlineBtn.contentTintColor = [NSColor labelColor];
    [((NSBox *)_leftToolBar).contentView addSubview:_outlineBtn];


    [_containerView addSubview:_leftToolBar];

    // ================= 侧边栏面板容器 =================
    _sidePanelView = [[NSView alloc] initWithFrame:NSMakeRect(toolBarWidth, 0, sidePanelWidth, _containerView.bounds.size.height)];
    _sidePanelView.autoresizingMask = NSViewHeightSizable | NSViewMaxXMargin;
    _sidePanelView.hidden = YES;

    NSView *panelBorder = appine_create_color_box(NSMakeRect(sidePanelWidth - 1, 0, 1, _containerView.bounds.size.height), [NSColor separatorColor], NSViewHeightSizable | NSViewMinXMargin);

    [_sidePanelView addSubview:panelBorder];

    [_containerView addSubview:_sidePanelView];

    // --- 大纲视图 ---
    _outlineScrollView = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, sidePanelWidth - 1, _sidePanelView.bounds.size.height)];
    _outlineScrollView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    _outlineScrollView.hasVerticalScroller = YES;
    _outlineScrollView.hidden = YES;

    _outlineView = [[NSOutlineView alloc] initWithFrame:_outlineScrollView.bounds];
    NSTableColumn *col = [[NSTableColumn alloc] initWithIdentifier:@"col"];
    col.width = sidePanelWidth - 20;
    [_outlineView addTableColumn:col];
    _outlineView.outlineTableColumn = col;
    _outlineView.headerView = nil;
    _outlineView.dataSource = self;
    _outlineView.delegate = self;
    _outlineScrollView.documentView = _outlineView;
    [_sidePanelView addSubview:_outlineScrollView];

    // --- 搜索视图 ---
    _searchPanelView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, sidePanelWidth - 1, _sidePanelView.bounds.size.height)];
    _searchPanelView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    _searchPanelView.hidden = YES;

    _sideSearchField = [[NSSearchField alloc] initWithFrame:NSMakeRect(10, _searchPanelView.bounds.size.height - 40, sidePanelWidth - 21, 22)];
    _sideSearchField.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    _sideSearchField.delegate = self;
    _sideSearchField.placeholderString = @"Search in PDF...";
    [_searchPanelView addSubview:_sideSearchField];

    _searchResultsScrollView = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, sidePanelWidth - 1, _searchPanelView.bounds.size.height - 50)];
    _searchResultsScrollView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    _searchResultsScrollView.hasVerticalScroller = YES;

    _searchResultsTableView = [[NSTableView alloc] initWithFrame:_searchResultsScrollView.bounds];
    NSTableColumn *searchCol = [[NSTableColumn alloc] initWithIdentifier:@"searchCol"];
    searchCol.width = sidePanelWidth - 20;
    [_searchResultsTableView addTableColumn:searchCol];
    _searchResultsTableView.headerView = nil;
    _searchResultsTableView.dataSource = self;
    _searchResultsTableView.delegate = self;
    _searchResultsTableView.rowHeight = 60; // 增加行高以显示上下文
    _searchResultsScrollView.documentView = _searchResultsTableView;
    [_searchPanelView addSubview:_searchResultsScrollView];

    [_sidePanelView addSubview:_searchPanelView];

    // 2. 创建 PDFView (注意 x 坐标从 toolBarWidth 开始)
    _pdfView = [[PDFView alloc] initWithFrame:NSMakeRect(toolBarWidth, 0, _containerView.bounds.size.width - toolBarWidth, _containerView.bounds.size.height)];
    [_pdfView setAutoScales:YES];
    [_pdfView setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
    [_containerView addSubview:_pdfView];

    [self setupAnnotationUI];
    [self setupSaveBar];

    // 监听文本选中事件，弹出 Primary Card
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(selectionChanged:) name:PDFViewSelectionChangedNotification object:_pdfView];

    // 使用最高优先级的事件监听，强行捕获 PDFView 内的鼠标点击
    __weak __typeof__(self) weakSelf = self;
    self.clickMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskLeftMouseUp handler:^NSEvent * _Nullable(NSEvent * _Nonnull event) {
        if (weakSelf && weakSelf.pdfView.window == event.window) {
            // 拦截点击在我们自定义 Menu 上的事件，防止触发 PDF 的空白处点击逻辑
            NSPoint ptInContainer = [weakSelf.containerView convertPoint:event.locationInWindow fromView:nil];
            if ((!weakSelf.primaryMenu.hidden && NSPointInRect(ptInContainer, weakSelf.primaryMenu.frame)) ||
                (!weakSelf.highlightMenu.hidden && NSPointInRect(ptInContainer, weakSelf.highlightMenu.frame)) ||
                (!weakSelf.commentMenu.hidden && NSPointInRect(ptInContainer, weakSelf.commentMenu.frame))) {
                return event;
            }
            NSPoint pt = [weakSelf.pdfView convertPoint:event.locationInWindow fromView:nil];
            if (NSPointInRect(pt, weakSelf.pdfView.bounds)) {
                [weakSelf handleMouseUpAtPoint:pt];
            }
        }
        return event;
    }];

    // 监听原生右键菜单对 PDF 的修改（捕获 UndoGroup 结束事件）
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(selectionChanged:) name:PDFViewSelectionChangedNotification object:_pdfView];

    // 监听 PDF 页面滚动，用于同步左侧大纲
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(pageChanged:) name:PDFViewPageChangedNotification object:_pdfView];
    // 监听滚动，防抖保存精确位置
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(pdfViewScrolled:) name:NSScrollViewDidLiveScrollNotification object:[self pdfScrollView]];
    // 监听 Cmd-S 快捷键保存
    // __weak __typeof__(self) weakSelf = self;
    self.eventMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown handler:^NSEvent * _Nullable(NSEvent * _Nonnull event) {
        if ((event.modifierFlags & NSEventModifierFlagCommand) && [[event.charactersIgnoringModifiers lowercaseString] isEqualToString:@"s"]) {
            if (weakSelf.isModified) {
                [weakSelf savePdf];
                return nil; // 拦截事件
            }
        }
        return event;
    }];
}

- (BOOL)gestureRecognizer:(NSGestureRecognizer *)gestureRecognizer shouldRecognizeSimultaneouslyWithGestureRecognizer:(NSGestureRecognizer *)otherGestureRecognizer {
    return YES; // 允许我们的点击手势与 PDFView 的原生手势同时触发
}


// ===========================================================================
// 融合后的搜索与跳转逻辑 (Cmd+F 触发)
// ===========================================================================

- (void)toggleFindBar {
    // 拦截 Cmd+F，直接打开侧边栏搜索
    if (self.currentSidePanelMode != 2) {
        self.currentSidePanelMode = 2;
        [self updateLayoutForSidePanel];
    }
    [self.sideSearchField.window makeFirstResponder:self.sideSearchField];
}

- (void)updateHighlights {
    if (self.searchResults.count == 0) {
        self.pdfView.highlightedSelections = nil;
        return;
    }

    NSMutableArray<PDFSelection *> *coloredSelections = [NSMutableArray arrayWithCapacity:self.searchResults.count];
    for (NSInteger i = 0; i < (NSInteger)self.searchResults.count; i++) {
        PDFSelection *sel = [self.searchResults[i] copy];
        // 当前选中的是橙色，其他是黄色
        if (i == self.currentMatchIndex) {
            sel.color = [NSColor colorWithRed:1.0 green:0.588 blue:0.196 alpha:1.0]; // #FF9632 (橙色)
        } else {
            sel.color = [NSColor yellowColor];
        }
        [coloredSelections addObject:sel];
    }

    self.pdfView.highlightedSelections = coloredSelections;
    if (self.currentMatchIndex >= 0 && self.currentMatchIndex < (NSInteger)coloredSelections.count) {
        [self.pdfView goToSelection:coloredSelections[self.currentMatchIndex]];
    }
}

- (void)findNext:(id)sender {
    if (self.searchResults.count == 0) return;
    NSInteger next = self.currentMatchIndex + 1;
    if (next >= (NSInteger)self.searchResults.count) next = 0;
    [self.searchResultsTableView selectRowIndexes:[NSIndexSet indexSetWithIndex:next] byExtendingSelection:NO];
    [self.searchResultsTableView scrollRowToVisible:next];
}

- (void)findPrevious:(id)sender {
    if (self.searchResults.count == 0) return;
    NSInteger prev = self.currentMatchIndex - 1;
    if (prev < 0) prev = self.searchResults.count - 1;
    [self.searchResultsTableView selectRowIndexes:[NSIndexSet indexSetWithIndex:prev] byExtendingSelection:NO];
    [self.searchResultsTableView scrollRowToVisible:prev];
}

#pragma mark - NSSearchFieldDelegate & NSTextFieldDelegate

- (void)controlTextDidChange:(NSNotification *)notification {
    NSTextField *field = notification.object;
    if (field == self.sideSearchField) {
        [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(performSideSearch) object:nil];
        [self performSelector:@selector(performSideSearch) withObject:nil afterDelay:0.3];
    }
}

- (BOOL)control:(NSControl *)control textView:(NSTextView *)textView doCommandBySelector:(SEL)commandSelector {
    if (control == self.sideSearchField) {
        // 在搜索框按 Enter 查找下一个，Shift+Enter 查找上一个
        if (commandSelector == @selector(insertNewline:)) {
            if ([NSEvent modifierFlags] & NSEventModifierFlagShift) {
                [self findPrevious:nil];
            } else {
                [self findNext:nil];
            }
            return YES;
        }
    }
    return NO;
}

#pragma mark - AppineBackend Protocol

- (NSView *)view {
    // 返回包含了 Find Bar 和 PDFView 的复合容器
    return self.containerView;
}

- (NSString *)title {
    return [self.path lastPathComponent] ?: @"PDF";
}

// ===========================================================================
// Annotation & Save 核心逻辑
// ===========================================================================

- (void)dealloc {
    if (_eventMonitor) [NSEvent removeMonitor:_eventMonitor];
    if (_clickMonitor) [NSEvent removeMonitor:_clickMonitor];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)cleanup {

    [self saveCurrentPosition];

    if (_eventMonitor) {
        [NSEvent removeMonitor:_eventMonitor];
        _eventMonitor = nil;
    }
    if (_clickMonitor) {
        [NSEvent removeMonitor:_clickMonitor];
        _clickMonitor = nil;
    }
    [[NSNotificationCenter defaultCenter] removeObserver:self];

    // 销毁可能正在运行的定时器，防止延迟释放
    if (_highlightMenuTimer) {
        [_highlightMenuTimer invalidate];
        _highlightMenuTimer = nil;
    }
}


- (void)setupSaveBar {
    CGFloat barHeight = 32.0;
    NSRect frame = self.containerView.frame;
    _saveBarView = appine_create_color_box(NSMakeRect(0, 0, frame.size.width, barHeight), [NSColor windowBackgroundColor], NSViewWidthSizable | NSViewMaxYMargin);
    _saveBarView.hidden = YES;

    NSTextField *label = [NSTextField labelWithString:@"已修改 (Unsaved Changes)"];
    label.frame = NSMakeRect(10, 8, 200, 16);
    [((NSBox *)_saveBarView).contentView addSubview:label];

    NSButton *saveBtn = [NSButton buttonWithTitle:@"保存 (Cmd-S)" target:self action:@selector(savePdf)];
    saveBtn.frame = NSMakeRect(frame.size.width - 120, 4, 100, 24);
    saveBtn.autoresizingMask = NSViewMinXMargin;

    [((NSBox *)_saveBarView).contentView addSubview:saveBtn];

}

- (void)setupAnnotationUI {
    // 1. Primary Menu (Highlight / Comment)
    _primaryMenu = appine_create_color_box(NSMakeRect(0, 0, 160, 40), [NSColor windowBackgroundColor], NSViewNotSizable);
    _primaryMenu.layer.cornerRadius = 8;
    _primaryMenu.layer.shadowOpacity = 0.3;
    _primaryMenu.hidden = YES;

    NSButton *hlBtn = [NSButton buttonWithTitle:@"Highlight" target:self action:@selector(actionHighlight)];
    hlBtn.frame = NSMakeRect(10, 8, 70, 24);
    NSButton *cmBtn = [NSButton buttonWithTitle:@"Note" target:self action:@selector(actionComment)];
    cmBtn.frame = NSMakeRect(85, 8, 70, 24);
    [((NSBox *)_primaryMenu).contentView addSubview:hlBtn];
    [((NSBox *)_primaryMenu).contentView addSubview:cmBtn];
    [self.containerView addSubview:_primaryMenu];

    // 2. Secondary Menus
    _highlightMenu = [self createSecondaryMenuWithComment:NO];
    _commentMenu = [self createSecondaryMenuWithComment:YES];
    [self.containerView addSubview:_highlightMenu];
    [self.containerView addSubview:_commentMenu];
}

- (NSView *)createSecondaryMenuWithComment:(BOOL)hasComment {
    // 1. 如果是 Note，高度设为 140 以容纳三行；如果是普通 Highlight，保持单行 40
    CGFloat height = hasComment ? 140 : 40;
    NSView *menu = appine_create_color_box(NSMakeRect(0, 0, 280, height), [NSColor windowBackgroundColor], NSViewNotSizable);

    menu.layer.cornerRadius = 8;
    menu.layer.shadowOpacity = 0.3;
    menu.hidden = YES;

    // 顶部左侧：样式按钮 [A], _A, ~A
    NSArray *styles = @[@"[A]", @"_A", @"~A"];
    for (int i=0; i<3; i++) {
        NSButton *btn = [NSButton buttonWithTitle:styles[i] target:self action:@selector(changeStyle:)];
        btn.tag = i; // 0: Highlight, 1: Underline, 2: StrikeOut
        btn.frame = NSMakeRect(10 + i*35, height - 32, 30, 24);
        [((NSBox *)menu).contentView addSubview:btn];
    }

    // 顶部右侧：删除按钮
    NSButton *delBtn = [NSButton buttonWithTitle:@"Del" target:self action:@selector(deleteAnnotation)];
    delBtn.frame = NSMakeRect(240, height - 32, 30, 24);
    [((NSBox *)menu).contentView addSubview:delBtn];

    // 颜色按钮
    NSArray *colors = @[[NSColor yellowColor], [NSColor greenColor], [NSColor blueColor], [NSColor redColor], [NSColor purpleColor]];
    for (int i=0; i<5; i++) {
        NSButton *btn = [NSButton buttonWithTitle:@"■" target:self action:@selector(changeColor:)];
        btn.tag = i;
        btn.contentTintColor = colors[i];

        // 动态布局：如果是 Note，颜色按钮放在底部左侧；如果是 Highlight，放在顶部中间
        CGFloat colorY = hasComment ? 8 : (height - 32);
        CGFloat colorX = hasComment ? (10 + i*25) : (120 + i*25);
        btn.frame = NSMakeRect(colorX, colorY, 20, 24);
        btn.bordered = NO;
        [((NSBox *)menu).contentView addSubview:btn];
    }

    // 中间：多行输入框 & 底部右侧：确认按钮
    if (hasComment) {
        _commentTextField = [NSTextField textFieldWithString:@""];
        // 占据中间区域 (y=40, 高度=65)
        _commentTextField.frame = NSMakeRect(10, 40, 260, 65);
        _commentTextField.placeholderString = @"Add a note here...";
        _commentTextField.usesSingleLineMode = NO;
        ((NSTextFieldCell *)_commentTextField.cell).wraps = YES;
        ((NSTextFieldCell *)_commentTextField.cell).scrollable = NO;
        [((NSBox *)menu).contentView addSubview:_commentTextField];

        // 确认按钮放在底部右侧
        NSButton *confirmBtn = [NSButton buttonWithTitle:@"Confirm" target:self action:@selector(confirmComment)];
        confirmBtn.frame = NSMakeRect(200, 8, 70, 24);
        [((NSBox *)menu).contentView addSubview:confirmBtn];
    }

    return menu;
}

- (void)positionMenu:(NSView *)menu atSelection:(PDFSelection *)selection {
    if (!selection || selection.pages.count == 0) return;
    NSRect bounds = [selection boundsForPage:selection.pages.firstObject];
    NSRect viewRect = [self.pdfView convertRect:bounds fromPage:selection.pages.firstObject];

    CGFloat x = NSMidX(viewRect) - menu.frame.size.width / 2;
    CGFloat y = NSMaxY(viewRect) + 10;

    // 边界检查
    if (x < 10) x = 10;
    if (x + menu.frame.size.width > self.containerView.frame.size.width) x = self.containerView.frame.size.width - menu.frame.size.width - 10;

    menu.frame = NSMakeRect(x, y, menu.frame.size.width, menu.frame.size.height);
    menu.hidden = NO;
}

- (void)selectionChanged:(NSNotification *)notif {
    if (self.pdfView.currentSelection.string.length > 0) {
        self.highlightMenu.hidden = YES;
        self.commentMenu.hidden = YES;
        [self positionMenu:self.primaryMenu atSelection:self.pdfView.currentSelection];
    } else {
        self.primaryMenu.hidden = YES;
    }
}

- (void)actionHighlight {
    [self createAnnotationWithComment:NO];
}

- (void)actionComment {
    [self createAnnotationWithComment:YES];
}

- (void)safeAddAnnotation:(PDFAnnotation *)ann toPage:(PDFPage *)page {
    NSUndoManager *undoMgr = self.pdfView.undoManager;
    // 注册撤销动作：如果撤销“添加”，就执行“删除”
    [[undoMgr prepareWithInvocationTarget:self] safeRemoveAnnotation:ann fromPage:page];
    [page addAnnotation:ann];
    [self markModified];
}

- (void)safeRemoveAnnotation:(PDFAnnotation *)ann fromPage:(PDFPage *)page {
    NSUndoManager *undoMgr = self.pdfView.undoManager;
    // 注册撤销动作：如果撤销“删除”，就执行“添加”
    [[undoMgr prepareWithInvocationTarget:self] safeAddAnnotation:ann toPage:page];
    [page removeAnnotation:ann];
    // 智能判断修改状态：如果撤销栈已经空了（说明回到了刚打开或者刚保存时的状态），则清除“已修改”标记
    // 注意：因为当前动作还在执行中，所以要在下一个 RunLoop 检查 canUndo 状态
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!undoMgr.canUndo) {
            self.isModified = NO;
            self.saveBarView.hidden = YES;
            APPINE_LOG(@"[appine] Undo stack is empty, document is now clean.");
        } else {
            [self markModified];
        }
    });
}

- (void)createAnnotationWithComment:(BOOL)hasComment {
    PDFSelection *selection = self.pdfView.currentSelection;
    if (!selection || selection.pages.count == 0) return;

    PDFPage *page = selection.pages.firstObject;
    NSRect bounds = [selection boundsForPage:page];

    // 1. 统一创建 Highlight 背景
    PDFAnnotation *ann = [[PDFAnnotation alloc] initWithBounds:bounds forType:PDFAnnotationSubtypeHighlight withProperties:nil];
    ann.color = [NSColor yellowColor];

    NSMutableArray *quadPoints = [NSMutableArray array];
    NSMutableArray<NSValue *> *rects = [NSMutableArray array]; // 记录每一行的局部矩形

    for (PDFSelection *line in [selection selectionsByLine]) {
        NSRect lineBounds = [line boundsForPage:page];

        CGFloat minX = NSMinX(lineBounds) - NSMinX(bounds);
        CGFloat maxX = NSMaxX(lineBounds) - NSMinX(bounds);
        CGFloat minY = NSMinY(lineBounds) - NSMinY(bounds);
        CGFloat maxY = NSMaxY(lineBounds) - NSMinY(bounds);

        [quadPoints addObject:[NSValue valueWithPoint:NSMakePoint(minX, maxY)]];
        [quadPoints addObject:[NSValue valueWithPoint:NSMakePoint(maxX, maxY)]];
        [quadPoints addObject:[NSValue valueWithPoint:NSMakePoint(minX, minY)]];
        [quadPoints addObject:[NSValue valueWithPoint:NSMakePoint(maxX, minY)]];

        if (hasComment) {
            [rects addObject:[NSValue valueWithRect:NSMakeRect(minX, minY, maxX - minX, maxY - minY)]];
        }
    }
    ann.quadrilateralPoints = quadPoints;
    [ann setShouldDisplay:YES];
    [ann setShouldPrint:YES];
    ann.userName = NSUserName() ?: @"User";
    ann.modificationDate = [NSDate date];

    // 开启撤销分组，确保高亮、边缘线、小方块能一次性撤销
    NSUndoManager *undoMgr = self.pdfView.undoManager;
    [undoMgr beginUndoGrouping];

    [self safeAddAnnotation:ann toPage:page];

    // [page addAnnotation:ann];

    // 2. 如果是 Comment，绘制包裹的边缘线
    if (hasComment && rects.count > 0) {
        PDFAnnotation *edgeAnn = [[PDFAnnotation alloc] initWithBounds:bounds forType:PDFAnnotationSubtypeInk withProperties:nil];
        edgeAnn.color = [NSColor blackColor]; // 黑色边缘
        edgeAnn.userName = @"AppineCommentEdge";

        NSBezierPath *path = [NSBezierPath bezierPath];
        NSUInteger n = rects.count;

        if (n == 1) {
            // 只有一行，直接画矩形
            [path appendBezierPathWithRect:[rects[0] rectValue]];
        } else {
            // 多行情况
            NSRect r1 = [rects[0] rectValue];
            NSRect rn_1 = [rects[n - 2] rectValue];
            NSRect rn = [rects[n - 1] rectValue];
            NSRect r2 = [rects[1] rectValue];

            // 按顺序连线
            // y ^
            //   |
            //   +---->
            //        x
            [path moveToPoint:NSMakePoint(NSMinX(r1) - 1, NSMaxY(r1))];    // R1 左上
            [path lineToPoint:NSMakePoint(NSMaxX(r1) + 1, NSMaxY(r1))];    // R1 右上
            [path lineToPoint:NSMakePoint(NSMaxX(rn_1) + 1, NSMinY(rn_1))];// R_{n-1} 右下
            [path lineToPoint:NSMakePoint(NSMaxX(rn) + 1, MIN(NSMaxY(rn),NSMinY(rn_1)))];    // R_n 右上
            [path lineToPoint:NSMakePoint(NSMaxX(rn) + 1, NSMinY(rn))];    // R_n 右下
            [path lineToPoint:NSMakePoint(NSMinX(rn) - 1, NSMinY(rn))];    // R_n 左下
            [path lineToPoint:NSMakePoint(NSMinX(r2) - 1, NSMaxY(r2))];    // R_2 左上
            [path lineToPoint:NSMakePoint(NSMinX(r1) - 1, MAX(NSMinY(r1), NSMaxY(r2)))];    // R_1 左下
            [path closePath]; // 自动闭合回到 R1 左上
        }

        path.lineWidth = 1.5;
        [edgeAnn addBezierPath:path];
        // [page addAnnotation:edgeAnn];
        [self safeAddAnnotation:edgeAnn toPage:page];
    }

    if (hasComment) {
        // 创建一个 Popup 注解，作为便签的可见图标
        NSRect popupBounds = NSMakeRect(NSMinX(bounds), NSMaxY(bounds), 20, 20);
        PDFAnnotation *popup = [[PDFAnnotation alloc] initWithBounds:popupBounds forType:PDFAnnotationSubtypePopup withProperties:nil];
        [self safeAddAnnotation:popup toPage:page];
        ann.popup = popup; // 将 Popup 与当前的高亮关联起来

        ann.contents = @"";
        self.commentTextField.stringValue = @"";
        [self positionMenu:self.commentMenu atSelection:selection];
    } else {
        [self positionMenu:self.highlightMenu atSelection:selection];
        [self startHighlightTimer];
    }

    // 结束撤销分组
    [undoMgr endUndoGrouping];
    [undoMgr setActionName:hasComment ? @"Add Note" : @"Add Highlight"];

    self.currentAnnotation = ann;
    self.primaryMenu.hidden = YES;
    [self.pdfView clearSelection];
    [self markModified];
}

- (void)startHighlightTimer {
    [self.highlightMenuTimer invalidate];
    self.highlightMenuTimer = [NSTimer scheduledTimerWithTimeInterval:5.0 repeats:NO block:^(NSTimer * _Nonnull timer) {
        self.highlightMenu.hidden = YES;
    }];
}

- (void)changeStyle:(NSButton *)sender {
    if (!self.currentAnnotation) return;
    NSString *type = PDFAnnotationSubtypeHighlight;
    if (sender.tag == 1) type = PDFAnnotationSubtypeUnderline;
    // if (sender.tag == 2) type = PDFAnnotationSubtypeSquiggly;
    if (sender.tag == 2) type = PDFAnnotationSubtypeStrikeOut;
    self.currentAnnotation.type = type;
    [self markModified];
    if (!self.highlightMenu.hidden) [self startHighlightTimer];
}

- (void)changeColor:(NSButton *)sender {
    if (!self.currentAnnotation) return;
    self.currentAnnotation.color = sender.contentTintColor;
    [self markModified];
    if (!self.highlightMenu.hidden) [self startHighlightTimer];
}

- (void)deleteAnnotation {
    if (self.currentAnnotation && self.currentAnnotation.page) {
        PDFPage *page = self.currentAnnotation.page;

        // 开启撤销分组
        NSUndoManager *undoMgr = self.pdfView.undoManager;
        [undoMgr beginUndoGrouping];

        // 1. 移除关联的 Popup
        if (self.currentAnnotation.popup) {
            [page removeAnnotation:self.currentAnnotation.popup];
        }

        // 2. 移除关联的边缘线 (Ink)
        PDFAnnotation *edgeToRemove = nil;
        for (PDFAnnotation *a in page.annotations) {
            // 通过我们刚才设定的 userName 标记和相同的 bounds 来精确定位边缘线
            if ([a.userName isEqualToString:@"AppineCommentEdge"] && NSEqualRects(a.bounds, self.currentAnnotation.bounds)) {
                edgeToRemove = a;
                break;
            }
        }
        if (edgeToRemove) {
            [page removeAnnotation:edgeToRemove];
        }

        // 3. 移除本体
        [page removeAnnotation:self.currentAnnotation];

        [undoMgr endUndoGrouping];
        [undoMgr setActionName:@"Delete Annotation"];
        self.currentAnnotation = nil;
        self.highlightMenu.hidden = YES;
        self.commentMenu.hidden = YES;
        [self markModified];
    }
}

- (void)confirmComment {
    if (self.currentAnnotation) {
        self.currentAnnotation.contents = self.commentTextField.stringValue;
        self.currentAnnotation.modificationDate = [NSDate date]; // 更新时间戳
        self.commentMenu.hidden = YES;
        [self markModified];
    }
}

- (void)handleMouseUpAtPoint:(NSPoint)pt {
    PDFPage *page = [self.pdfView pageForPoint:pt nearest:NO];
    if (!page) return;

    NSPoint pagePoint = [self.pdfView convertPoint:pt toPage:page];
    PDFAnnotation *ann = [page annotationAtPoint:pagePoint];
    APPINE_LOG(@"[Appine Debug] 点击页面坐标: %@, 捕获到注解类型: %@", NSStringFromPoint(pagePoint), ann ? ann.type : @"无");

    if (ann) {
        // 如果点到了原生的 Popup 黄色方块，我们要通过遍历找到它的父节点（即高亮本身）
        if ([ann.type isEqualToString:@"Popup"]) {
            for (PDFAnnotation *parentAnn in page.annotations) {
                if (parentAnn.popup == ann) {
                    ann = parentAnn;
                    APPINE_LOG(@"[Appine Debug] 成功回溯找到父节点高亮");
                    break;
                }
            }
        }
        //如果点到了我们画的边缘线，回溯找到对应的高亮 ---
        if ([ann.type isEqualToString:@"Ink"] && [ann.userName isEqualToString:@"AppineCommentEdge"]) {
            for (PDFAnnotation *parentAnn in page.annotations) {
                if ([parentAnn.type isEqualToString:@"Highlight"] && NSEqualRects(parentAnn.bounds, ann.bounds)) {
                    ann = parentAnn;
                    APPINE_LOG(@"[Appine Debug] 成功回溯找到边缘线对应的高亮");
                    break;
                }
            }
        }

        // 使用硬编码字符串比对，防止底层常量指针不一致导致判断失败
        if ([ann.type isEqualToString:@"Highlight"] ||
            [ann.type isEqualToString:@"Underline"] ||
            [ann.type isEqualToString:@"StrikeOut"]) {

            APPINE_LOG(@"[Appine Debug] 确认点击了文本标记，准备弹出菜单");
            self.currentAnnotation = ann;
            NSRect viewRect = [self.pdfView convertRect:ann.bounds fromPage:page];

            // 检查是否有评论内容，或者是否有关联的边缘线（判断为 Note）
            BOOL isComment = (ann.popup != nil || (ann.contents && ann.contents.length > 0));
            if (!isComment) {
                for (PDFAnnotation *edge in page.annotations) {
                    if ([edge.type isEqualToString:@"Ink"] && [edge.userName isEqualToString:@"AppineCommentEdge"] && NSEqualRects(edge.bounds, ann.bounds)) {
                        isComment = YES;
                        break;
                    }
                }
            }

            if (isComment) {
                APPINE_LOG(@"[Appine Debug] 这是一个 Comment，弹出 Comment Menu");
                self.commentTextField.stringValue = ann.contents ?: @"";
                self.highlightMenu.hidden = YES;

                CGFloat x = NSMidX(viewRect) - self.commentMenu.frame.size.width / 2;
                self.commentMenu.frame = NSMakeRect(x, NSMaxY(viewRect) + 10, self.commentMenu.frame.size.width, self.commentMenu.frame.size.height);
                self.commentMenu.hidden = NO;
            } else {
                APPINE_LOG(@"[Appine Debug] 这是一个纯 Highlight，弹出 Highlight Menu");
                self.commentMenu.hidden = YES;

                CGFloat x = NSMidX(viewRect) - self.highlightMenu.frame.size.width / 2;
                self.highlightMenu.frame = NSMakeRect(x, NSMaxY(viewRect) + 10, self.highlightMenu.frame.size.width, self.highlightMenu.frame.size.height);
                self.highlightMenu.hidden = NO;
                [self startHighlightTimer];
            }
            return;
        }
    }

    // 点击空白处隐藏菜单
    self.highlightMenu.hidden = YES;
    if (self.commentMenu.hidden == NO && [self.commentTextField.stringValue isEqualToString:@""]) {
        self.commentMenu.hidden = YES;
    }
}

- (void)markModified {
    self.isModified = YES;
    self.saveBarView.hidden = NO;
}

- (void)savePdf {
    if (self.path) {
        NSURL *url = [NSURL fileURLWithPath:self.path];
        BOOL success = [self.pdfView.document writeToURL:url];
        if (success) {
            self.isModified = NO;
            self.saveBarView.hidden = YES;
            APPINE_LOG(@"[Appine] PDF 批注保存成功！");
        } else {
            APPINE_LOG(@"[Appine] PDF 保存失败！");
        }
    }
}

// 只响应当前 PDF 的撤销事件
- (void)undoManagerDidClose:(NSNotification *)notif {
    if (notif.object == self.pdfView.undoManager) {
        [self markModified];
    }
}

// PDFView 没有公开 scrollView 接口，通过子视图遍历获取
- (NSScrollView *)pdfScrollView {
    for (NSView *subview in self.pdfView.subviews) {
        if ([subview isKindOfClass:[NSScrollView class]]) {
            return (NSScrollView *)subview;
        }
    }
    return nil;
}

// 保存当前阅读位置到 NSUserDefaults
- (void)saveCurrentPosition {
    if (!self.pdfView.document || !self.path) return;
    // 用 scrollView 的 documentVisibleRect origin 保存精确滚动位置
    NSScrollView *scrollView = [self pdfScrollView];
    if (!scrollView) return;
    NSPoint scrollOrigin = scrollView.documentVisibleRect.origin;
    NSString *key = [NSString stringWithFormat:@"AppinePDFPos_%@", self.path];
    NSDictionary *dict = @{@"scrollX": @(scrollOrigin.x), @"scrollY": @(scrollOrigin.y)};
    [[NSUserDefaults standardUserDefaults] setObject:dict forKey:key];
    APPINE_LOG(@"[Appine] saveCurrentPosition: scrollOrigin=%@", NSStringFromPoint(scrollOrigin));
}

// 恢复上次阅读位置
- (void)restoreLastPosition {
    APPINE_LOG(@"[Appine] restoreLastPosition called, path=%@, hasDoc=%d", self.path, self.pdfView.document != nil);
    if (!self.pdfView.document || !self.path) return;
    NSString *key = [NSString stringWithFormat:@"AppinePDFPos_%@", self.path];
    NSDictionary *dict = [[NSUserDefaults standardUserDefaults] dictionaryForKey:key];
    APPINE_LOG(@"[Appine] restoreLastPosition key=%@, dict=%@", key, dict);
    if (dict) {
        NSPoint scrollOrigin = NSMakePoint([dict[@"scrollX"] doubleValue], [dict[@"scrollY"] doubleValue]);
        APPINE_LOG(@"[Appine] restoreLastPosition: scrollOrigin=%@", NSStringFromPoint(scrollOrigin));

        __weak __typeof__(self) weakSelf = self;
        __block id observer = [[NSNotificationCenter defaultCenter]
            addObserverForName:NSViewFrameDidChangeNotification
                        object:self.pdfView
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(NSNotification *note) {
                        if (weakSelf.pdfView.frame.size.height > 0) {
                            NSScrollView *scrollView = [weakSelf pdfScrollView];
                            if (scrollView) {
                                APPINE_LOG(@"[Appine] restoreLastPosition: applying scrollOrigin=%@",
                                      NSStringFromPoint(scrollOrigin));
                                [scrollView.documentView scrollPoint:scrollOrigin];
                            }
                            [[NSNotificationCenter defaultCenter] removeObserver:observer];
                            observer = nil;
                            dispatch_async(dispatch_get_main_queue(), ^{
                                weakSelf.isSavePositionEnabled = YES;
                            });
                        }
                    }];
    } else {
        _isSavePositionEnabled = YES;
    }
}

// ===========================================================================
// 侧边栏面板控制与搜索逻辑
// ===========================================================================

- (void)updateLayoutForSidePanel {
    CGFloat toolBarWidth = 40.0;
    CGFloat sidePanelWidth = 250.0;

    BOOL showPanel = self.currentSidePanelMode != 0;
    self.sidePanelView.hidden = !showPanel;

    self.outlineScrollView.hidden = (self.currentSidePanelMode != 1);
    self.searchPanelView.hidden = (self.currentSidePanelMode != 2);

    // 动态调整 PDFView 的宽度
    CGFloat pdfX = toolBarWidth + (showPanel ? sidePanelWidth : 0);
    NSRect pdfFrame = NSMakeRect(pdfX, 0, self.containerView.bounds.size.width - pdfX, self.containerView.bounds.size.height);

    self.pdfView.frame = pdfFrame;

    // 更新按钮高亮状态 (macOS 按钮选中效果)
    self.outlineBtn.state = (self.currentSidePanelMode == 1) ? NSControlStateValueOn : NSControlStateValueOff;
    self.searchBtn.state = (self.currentSidePanelMode == 2) ? NSControlStateValueOn : NSControlStateValueOff;
}

- (void)toggleOutlinePanel {
    if (self.currentSidePanelMode == 1) {
        self.currentSidePanelMode = 0; // 再次点击关闭
    } else {
        self.currentSidePanelMode = 1;
        [self.outlineView reloadData];
    }
    [self updateLayoutForSidePanel];
}

- (void)toggleSearchPanel {
    if (self.currentSidePanelMode == 2) {
        self.currentSidePanelMode = 0; // 再次点击关闭
    } else {
        self.currentSidePanelMode = 2;
        [self.sideSearchField.window makeFirstResponder:self.sideSearchField];
    }
    [self updateLayoutForSidePanel];
}

// 侧边栏异步流式搜索
- (void)performSideSearch {
    NSString *query = self.sideSearchField.stringValue;

    // 取消之前的搜索并清空结果
    [self.pdfView.document cancelFindString];
    [self.searchResults removeAllObjects];
    self.currentMatchIndex = -1;
    [self.searchResultsTableView reloadData];
    [self updateHighlights];

    if (query.length > 0) {
        // 使用 PDFKit 的异步流式搜索，结果会通过 didMatchString: 代理返回
        [self.pdfView.document beginFindString:query withOptions:NSCaseInsensitiveSearch];
    }
}

// PDFDocumentDelegate 搜索结果回调
- (void)didMatchString:(PDFSelection *)instance {
    // 每次匹配到一个结果就会回调一次
    [self.searchResults addObject:instance];
    [self.searchResultsTableView reloadData];

    if (self.currentMatchIndex == -1) {
        self.currentMatchIndex = 0;
        // 自动选中并滚动到第一个结果
        [self.searchResultsTableView selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
        [self.searchResultsTableView scrollRowToVisible:0];
    }

    // 防抖更新高亮，防止搜索结果过多时卡死主线程
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(updateHighlights) object:nil];
    [self performSelector:@selector(updateHighlights) withObject:nil afterDelay:0.1];
}


// ===========================================================================
// NSTableView DataSource & Delegate (侧边栏搜索结果)
// ===========================================================================

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    return self.searchResults.count;
}

- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row {
    NSTableCellView *cell = [tableView makeViewWithIdentifier:@"SearchCell" owner:nil];
    if (!cell) {
        cell = [[NSTableCellView alloc] initWithFrame:NSMakeRect(0, 0, tableColumn.width, 60)];
        cell.identifier = @"SearchCell";

        // 页码标签
        NSTextField *pageLabel = [NSTextField labelWithString:@""];
        pageLabel.frame = NSMakeRect(5, 40, tableColumn.width - 10, 16);
        pageLabel.font = [NSFont systemFontOfSize:11 weight:NSFontWeightBold];
        pageLabel.textColor = [NSColor secondaryLabelColor];
        pageLabel.tag = 101;
        [cell addSubview:pageLabel];

        // 上下文内容标签
        NSTextField *contentLabel = [NSTextField wrappingLabelWithString:@""];
        contentLabel.frame = NSMakeRect(5, 5, tableColumn.width - 10, 35);
        contentLabel.font = [NSFont systemFontOfSize:12];
        contentLabel.maximumNumberOfLines = 2;
        contentLabel.tag = 102;
        [cell addSubview:contentLabel];
    }

    PDFSelection *sel = self.searchResults[row];
    NSTextField *pageLabel = [cell viewWithTag:101];
    NSTextField *contentLabel = [cell viewWithTag:102];

    // 获取页码
    if (sel.pages.count > 0) {
        PDFPage *page = sel.pages.firstObject;
        NSUInteger pageIndex = [self.pdfView.document indexForPage:page];
        pageLabel.stringValue = [NSString stringWithFormat:@"第 %lu 页", (unsigned long)(pageIndex + 1)];
    }

    // 扩展 Selection 以获取上下文 (前后各取 20 个字符)
    PDFSelection *extendedSel = [sel copy];
    [extendedSel extendSelectionAtStart:20];
    [extendedSel extendSelectionAtEnd:20];
    // 去除换行符，使排版更紧凑
    NSString *contextStr = [extendedSel.string stringByReplacingOccurrencesOfString:@"\n" withString:@" "];

    // 使用富文本在 Chunk 中高亮搜索词
    NSMutableAttributedString *attrStr = [[NSMutableAttributedString alloc] initWithString:contextStr ?: @""];
    NSString *query = self.sideSearchField.stringValue;
    if (query.length > 0 && contextStr) {
        NSRange range = [contextStr rangeOfString:query options:NSCaseInsensitiveSearch];
        if (range.location != NSNotFound) {
            [attrStr addAttribute:NSBackgroundColorAttributeName value:[NSColor yellowColor] range:range];
            [attrStr addAttribute:NSForegroundColorAttributeName value:[NSColor blackColor] range:range];
            [attrStr addAttribute:NSFontAttributeName value:[NSFont systemFontOfSize:12 weight:NSFontWeightBold] range:range];
        }
    }
    contentLabel.attributedStringValue = attrStr;

    return cell;
}

- (void)tableViewSelectionDidChange:(NSNotification *)notification {
    NSInteger row = self.searchResultsTableView.selectedRow;
    if (row >= 0 && row < (NSInteger)self.searchResults.count) {
        self.currentMatchIndex = row;
        [self updateHighlights]; // 触发 PDF 正文的颜色更新与跳转
    }
}

// NSOutlineView DataSource & Delegate
- (NSInteger)outlineView:(NSOutlineView *)outlineView numberOfChildrenOfItem:(id)item {
    PDFOutline *outline = item ? (PDFOutline *)item : self.pdfView.document.outlineRoot;
    return outline ? outline.numberOfChildren : 0;
}

- (id)outlineView:(NSOutlineView *)outlineView child:(NSInteger)index ofItem:(id)item {
    PDFOutline *outline = item ? (PDFOutline *)item : self.pdfView.document.outlineRoot;
    return [outline childAtIndex:index];
}

- (BOOL)outlineView:(NSOutlineView *)outlineView isItemExpandable:(id)item {
    return ((PDFOutline *)item).numberOfChildren > 0;
}

- (id)outlineView:(NSOutlineView *)outlineView objectValueForTableColumn:(NSTableColumn *)tableColumn byItem:(id)item {
    return ((PDFOutline *)item).label;
}

- (void)outlineViewSelectionDidChange:(NSNotification *)notification {
    NSInteger row = [self.outlineView selectedRow];
    if (row >= 0) {
        PDFOutline *outline = [self.outlineView itemAtRow:row];
        if (outline.destination) {
            [self.pdfView goToDestination:outline.destination];
        } else if (outline.action) {
            [self.pdfView performAction:outline.action];
        }
    }
}

// ===========================================================================
// 大纲同步逻辑
// ===========================================================================
- (void)pdfViewScrolled:(NSNotification *)notif {
    if (!self.isSavePositionEnabled) return;
    // 防抖：0.5s 内连续滚动只保存最后一次
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(saveCurrentPosition) object:nil];
    [self performSelector:@selector(saveCurrentPosition) withObject:nil afterDelay:0.5];
}

- (void)pageChanged:(NSNotification *)notif {
    // 文档就绪前禁止保存，防止初始化时的假翻页覆盖存档
    // 翻页也触发一次保存（scrolled 通知不一定在翻页时触发）
    if (self.isSavePositionEnabled) {
        [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(saveCurrentPosition) object:nil];
        [self performSelector:@selector(saveCurrentPosition) withObject:nil afterDelay:0.3];
    }

    if (self.currentSidePanelMode != 1) return; // 只有大纲显示时才同步
    PDFPage *page = self.pdfView.currentPage;
    if (!page) return;

    PDFOutline *bestNode = [self findBestOutlineNodeForPage:page];
    if (bestNode) {
        NSInteger row = [self.outlineView rowForItem:bestNode];
        if (row >= 0) {
            [self.outlineView selectRowIndexes:[NSIndexSet indexSetWithIndex:row] byExtendingSelection:NO];
            [self.outlineView scrollRowToVisible:row];
        }
    }
}

// 寻找最接近且不超过当前页码的大纲节点
- (PDFOutline *)findBestOutlineNodeForPage:(PDFPage *)page {
    if (!self.pdfView.document.outlineRoot) return nil;
    NSUInteger targetPageIndex = [self.pdfView.document indexForPage:page];

    PDFOutline *bestNode = nil;
    NSUInteger bestPageIndex = 0;

    // 调用标准的 Objective-C 方法进行递归，传入指针以更新结果
    [self traverseOutlineNode:self.pdfView.document.outlineRoot
              targetPageIndex:targetPageIndex
                     bestNode:&bestNode
                bestPageIndex:&bestPageIndex];

    return bestNode;
}

// 递归遍历大纲树的辅助方法（替代 Block 以彻底消除循环引用警告）
- (void)traverseOutlineNode:(PDFOutline *)node
            targetPageIndex:(NSUInteger)targetPageIndex
                   bestNode:(PDFOutline **)bestNode
              bestPageIndex:(NSUInteger *)bestPageIndex {
    if (!node) return;

    PDFPage *nodePage = nil;
    if (node.destination) {
        nodePage = node.destination.page;
    } else if (node.action && [node.action isKindOfClass:[PDFActionGoTo class]]) {
        nodePage = ((PDFActionGoTo *)node.action).destination.page;
    }

    if (nodePage) {
        NSUInteger nodePageIndex = [self.pdfView.document indexForPage:nodePage];
        // 找到页码小于等于当前页，且最靠后的节点
        if (nodePageIndex <= targetPageIndex && nodePageIndex >= *bestPageIndex) {
            *bestNode = node;
            *bestPageIndex = nodePageIndex;
        }
    }

    // 递归遍历子节点
    for (NSInteger i = 0; i < (NSInteger)node.numberOfChildren; i++) {
        [self traverseOutlineNode:[node childAtIndex:i]
                  targetPageIndex:targetPageIndex
                         bestNode:bestNode
                    bestPageIndex:bestPageIndex];
    }
}



@end

// C API export
id<AppineBackend> appine_create_pdf_backend(NSString *path) {
    return [[AppinePdfBackend alloc] initWithPath:path];
}

/*
 * Filename: appine_core.m
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

#import <stdatomic.h>
#import <signal.h>
#import <Cocoa/Cocoa.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import "appine_core.h"
#import "appine_backend.h"

// ===========================================================================
// Log module, for debug
// ===========================================================================
BOOL g_appine_debug_log = NO;

void appine_core_set_debug_log(int enable) {
    g_appine_debug_log = (enable != 0);
    NSLog(@"[appine] Debug logging %@", g_appine_debug_log ? @"enabled" : @"disabled");
}

// ===========================================================================
// 辅助 SIGUSR1 信号源判断
// ===========================================================================
static atomic_bool appine_deactivate_flag = false;
bool appine_core_check_signal(void) {
    // 检查并重置为 false
    return atomic_exchange(&appine_deactivate_flag, false);
}

#pragma mark - Backends

extern id<AppineBackend> appine_create_web_backend(NSString *urlString);
extern id<AppineBackend> appine_create_pdf_backend(NSString *path);
extern id<AppineBackend> appine_create_quicklook_backend(NSString *path);
extern id<AppineBackend> appine_create_rss_backend(NSString *path);

static id<AppineBackend> appine_create_backend_for_file(NSString *path) {
    // 智能判断使用appine_create_quicklook_backend, appine_create_pdf_backend
    // 或者 appine_create_web_backend
    if (!path || path.length == 0) return nil;

    UTType *fileType = [UTType typeWithFilenameExtension:path.pathExtension];

    if ([fileType conformsToType:UTTypePDF]) {
        return appine_create_pdf_backend(path);
    }
    else if ([fileType conformsToType:UTTypeHTML] ||
             [fileType conformsToType:UTTypeWebArchive]) {
        NSURL *url = [NSURL fileURLWithPath:path];
        return appine_create_web_backend(url.absoluteString);
    }
    else {
        BOOL isSafeForQuickLook = NO;

        if (fileType != nil) {
            // 【白名单】
            NSArray<UTType *> *safeTypes = @[
                UTTypeContent, UTTypeText, UTTypeSourceCode,
                UTTypeScript, UTTypeLog, UTTypeJSON, UTTypeXML
            ];
            for (UTType *safeType in safeTypes) {
                if ([fileType conformsToType:safeType]) {
                    isSafeForQuickLook = YES;
                    break;
                }
            }

            // 【黑名单】
            if ([fileType conformsToType:UTTypeExecutable] ||
                [fileType conformsToType:UTTypeArchive] ||
                [fileType conformsToType:UTTypeDiskImage] ||
                [fileType conformsToType:UTTypeApplication] ||
                [fileType conformsToType:UTTypePluginBundle] ||
                [fileType conformsToType:UTTypeFramework] ||
                [fileType conformsToType:UTTypeFolder]) {
                isSafeForQuickLook = NO;
            }
        }

        if (isSafeForQuickLook) {
            return appine_create_quicklook_backend(path);
        } else {
            NSString *ext = path.pathExtension.length > 0 ? path.pathExtension : @"无后缀/未知";
            APPINE_LOG(@"[Appine] 拦截了不支持或可能导致崩溃的文件类型: %@", ext);

            NSAlert *alert = [[NSAlert alloc] init];
            alert.messageText = @"不支持预览该文件";
            alert.informativeText = [NSString stringWithFormat:@"Appine can’t safely preview this type of file (%@).\nPreview has been blocked.\nAppine 无法安全地预览此类型的文件。\n为防止底层渲染服务崩溃，已拦截此操作。", ext];
            [alert runModal];
            return nil;
        }
    }
}


static const CGFloat kAppineToolbarHeight = 34.0;
static const CGFloat kAppineTabBarHeight = 28.0;

#pragma mark - Models & State

@interface AppineTabItem : NSObject
@property(nonatomic, assign) NSInteger tabId;
@property(nonatomic, strong) id<AppineBackend> backend;
@property(nonatomic, copy) NSString *originalPath;
@end
@implementation AppineTabItem
@end

@interface AppineState : NSObject
@property(nonatomic, weak) NSWindow *hostWindow;
@property(nonatomic, strong) NSView *containerView;
@property(nonatomic, strong) NSBox *toolbarView;
@property(nonatomic, strong) NSStackView *toolbarStack;
@property(nonatomic, strong) NSBox *tabBarView;
@property(nonatomic, strong) NSSegmentedControl *tabControl;
@property(nonatomic, strong) NSBox *contentHostView;
@property(nonatomic, strong) NSView *inactiveOverlayView;
@property(nonatomic, strong) NSTextField *statusLabel;
@property(nonatomic, strong) NSMutableArray<AppineTabItem *> *tabs;
@property(nonatomic, assign) NSInteger activeTabId;
@property(nonatomic, assign) NSInteger nextTabId;
@property(nonatomic, assign) NSRect targetRect;
@property(nonatomic, assign) BOOL isActive;
@end
@implementation AppineState
@end

static AppineState *appine_state(void) {
    static AppineState *g_state = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        g_state = [[AppineState alloc] init];
        g_state.tabs = [NSMutableArray array];
        g_state.activeTabId = -1;
        g_state.nextTabId = 1;
    });
    return g_state;
}

#pragma mark - Helpers

static NSView *appine_get_emacs_view(void) {
    AppineState *state = appine_state();
    if (!state.hostWindow) return nil;

    // 1. 尝试从 superview 往上找
    NSView *emacsView = state.containerView;
    while (emacsView) {
        emacsView = emacsView.superview;
        if ([emacsView.className containsString:@"Emacs"]) {
            return emacsView;
        }
    }
    // 2. 如果没找到，从 window.contentView 找
    emacsView = state.hostWindow.contentView;
    if ([emacsView.className containsString:@"Emacs"]) {
        return emacsView;
    }
    // 3. 尝试从 subviews 里面找
    for (NSView *sub in emacsView.subviews) {
        if ([sub.className containsString:@"Emacs"]) {
            return sub;
        }
    }
     // 4. 兜底返回 contentView
    return state.hostWindow.contentView;
}

// 递归查找真正的可滚动视图 (NSScrollView 或 PDFView)
static NSView *appine_find_scroll_target(NSView *view) {
    if (!view) return nil;

    // 1. 如果本身就是 NSScrollView (这会匹配到 WKWebView 内部私有的 WKScrollView)
    if ([view isKindOfClass:[NSScrollView class]]) {
        return view;
    }

    // 2. 递归查找子视图
    for (NSView *subview in view.subviews) {
        NSView *found = appine_find_scroll_target(subview);
        if (found) return found;
    }

    // 3. 如果实在找不到 NSScrollView，退回到返回 WKWebView 或 PDFView 本身
    if ([view isKindOfClass:NSClassFromString(@"WKWebView")] ||
        [view isKindOfClass:NSClassFromString(@"PDFView")]) {
        return view;
    }

    return nil;
}
// 递归查找真正需要接收键盘焦点的视图 (WKWebView 或 PDFView)
static NSView *appine_find_focus_target(NSView *view) {
    if (!view) return nil;

    // 1. 如果本身就是 WKWebView 或 PDFView，直接返回
    if ([view isKindOfClass:NSClassFromString(@"WKWebView")] ||
        [view isKindOfClass:NSClassFromString(@"PDFView")]) {
        return view;
    }
    // 2. 递归查找子视图
    for (NSView *subview in view.subviews) {
        NSView *found = appine_find_focus_target(subview);
        if ([found isKindOfClass:NSClassFromString(@"WKWebView")] ||
            [found isKindOfClass:NSClassFromString(@"PDFView")]) {
            return found;
        }
    }
    // 3. 兜底返回原视图
    return view;
}

static AppineTabItem *appine_find_tab(NSInteger tabId) {
    for (AppineTabItem *item in appine_state().tabs) {
        if (item.tabId == tabId) return item;
    }
    return nil;
}

// 如果当前 Appine 是激活状态，则强制将 macOS 焦点对齐到当前活跃的视图上
static void appine_restore_focus_if_active(void) {
    AppineState *state = appine_state();
    if (state.isActive && state.hostWindow) {
        AppineTabItem *active = appine_find_tab(state.activeTabId);
        if (active && active.backend && active.backend.view) {
            // 查找真正的焦点目标，而不是把焦点给 NSView 容器
            NSView *focusTarget = appine_find_focus_target(active.backend.view);
            APPINE_LOG(@"Restoring focus. Backend view: %@, Focus target: %@",
                       [active.backend.view className], [focusTarget className]);
            [state.hostWindow makeFirstResponder:focusTarget];
        }
    }
}

static AppineBackendKind appine_active_backend_kind(void) {
    AppineState *state = appine_state();
    AppineTabItem *active = appine_find_tab(state.activeTabId);
    if (!active || !active.backend) return AppineBackendKindUnknown;
    if ([active.backend respondsToSelector:@selector(kind)]) {
        return active.backend.kind;
    }
    return AppineBackendKindUnknown;
}

static NSWindow *appine_target_window(void) {
    AppineState *state = appine_state();
    if (state.hostWindow) return state.hostWindow;
    if ([NSApp keyWindow]) return [NSApp keyWindow];
    return [[NSApp windows] firstObject];
}

static void appine_apply_visual_state(void);
static void appine_apply_rect(void);
static void appine_rebuild_tabs(void);
static void appine_attach_active_view(void);
static void appine_set_active(BOOL active);
static void appine_add_tab(id<AppineBackend> backend, NSString *originalPath);
static void appine_save_session(void);
static void appine_restore_session_if_needed(void);

#pragma mark - Core Magic Overlay

@interface AppineInactiveOverlayView : NSView
@end
@implementation AppineInactiveOverlayView
- (BOOL)isOpaque { return NO; }
- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    // 自适应颜色的半透明遮罩
    [[[NSColor windowBackgroundColor] colorWithAlphaComponent:0.05] setFill];
    NSRectFillUsingOperation(self.bounds, NSCompositingOperationSourceOver);
    [[NSColor separatorColor] setStroke]; // 边框也使用系统自适应分割线颜色
    NSBezierPath *path = [NSBezierPath bezierPathWithRect:NSInsetRect(self.bounds, 0.5, 0.5)];
    [path setLineWidth:1.0];
    [path stroke];
}
- (NSView *)emacsTargetViewForEvent:(NSEvent *)event {
    AppineState *state = appine_state();
    if (!state.containerView) return self.window.contentView;
    BOOL wasHidden = state.containerView.isHidden;
    state.containerView.hidden = YES;
    NSView *target = [self.window.contentView hitTest:event.locationInWindow];
    state.containerView.hidden = wasHidden;
    return target ?: self.window.contentView;
}

- (void)mouseDown:(NSEvent *)e {
    AppineState *state = appine_state();
    NSView *nativeTarget = nil;
    if (state.containerView) {
        BOOL overlayWasHidden = self.isHidden;
        self.hidden = YES;
        nativeTarget = [self.window.contentView hitTest:e.locationInWindow];
        self.hidden = overlayWasHidden;
    }

    BOOL isNativeControl = (nativeTarget && (nativeTarget == state.tabControl || [nativeTarget isKindOfClass:[NSControl class]]));
    NSView *target = [self emacsTargetViewForEvent:e];

    APPINE_LOG(@"Overlay mouseDown forwarded to: %@, nativeTarget: %@", [target className], [nativeTarget className]);

    if (target && target != self) {
        [self.window makeFirstResponder:target];
        [target mouseDown:e];
    } else {
        [super mouseDown:e];
    }

    if (isNativeControl) {
        APPINE_LOG(@"Also forwarding mouseDown to native control: %@", [nativeTarget className]);
        [nativeTarget mouseDown:e];
    }
}
- (void)mouseDragged:(NSEvent *)e {
    NSView *target = [self emacsTargetViewForEvent:e];
    if (target && target != self) [target mouseDragged:e];
    else [super mouseDragged:e];
}
- (void)mouseUp:(NSEvent *)e {
    NSView *target = [self emacsTargetViewForEvent:e];
    if (target && target != self) [target mouseUp:e];
    else [super mouseUp:e];
}
@end

#pragma mark - UI Targets

@interface AppineActionTarget : NSObject
@end
@implementation AppineActionTarget
- (void)focusAndSendAction:(SEL)action {
    appine_set_active(YES);
    if (![NSApp sendAction:action to:nil from:nil]) {
        APPINE_LOG(@"[appine] action not handled: %@", NSStringFromSelector(action));
    }
}
- (BOOL)sendScrollActionHandled:(SEL)action {
    appine_set_active(YES);
    AppineState *state = appine_state();
    AppineTabItem *active = appine_find_tab(state.activeTabId);

    if (active && active.backend && active.backend.view) {
        NSView *backendView = active.backend.view;
        NSView *targetView = appine_find_scroll_target(backendView);

        if (targetView) {
            // 仅当目标确实支持该 selector 才发送并吞键
            if ([targetView respondsToSelector:action]) {
                [NSApp sendAction:action to:targetView from:self];
                return YES;
            }
            // fallback 1: superview 链
            NSView *v = targetView.superview;
            while (v) {
                if ([v respondsToSelector:action]) {
                    [NSApp sendAction:action to:v from:self];
                    return YES;
                }
                v = v.superview;
            }
            // fallback 2: backend 根视图
            if ([active.backend.view respondsToSelector:action]) {
                [NSApp sendAction:action to:active.backend.view from:self];
                return YES;
            }
        }
    }
    APPINE_LOG(@"[appine] scroll target not found for action: %@", NSStringFromSelector(action));
    return NO;
}


- (void)deactivate:(id)sender {
    // Appine Window 失去焦点，更新 UI 状态
    appine_set_active(NO);
    // 标记这个信号是我们发出的
    atomic_store(&appine_deactivate_flag, true);
    // 发送给整个进程，让 Emacs 的主线程去捕获它
    kill(getpid(), SIGUSR1);
}
- (void)newTab:(id)sender { (void)sender; appine_add_tab(appine_create_web_backend(@"https://google.com"), @"https://google.com"); }
- (void)closeTab:(id)sender { (void)sender; appine_core_close_active_tab(); }
- (void)openFile:(id)sender {
    (void)sender;
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.canChooseFiles = YES;
    panel.canChooseDirectories = NO;

    if ([panel runModal] == NSModalResponseOK && panel.URL) {
        NSString *path = panel.URL.path;
        id<AppineBackend> backend = appine_create_backend_for_file(path);
        if (backend) {
          appine_add_tab(backend, path);
        }
    }
}
- (void)undo:(id)sender {
    (void)sender;
    appine_set_active(YES);
    AppineState *state = appine_state();
    AppineTabItem *active = appine_find_tab(state.activeTabId);

    APPINE_LOG(@"[appine] ======================================");
    APPINE_LOG(@"[appine] Action: undo: triggered from Toolbar or Cmd-Z");

    if (active && active.backend) {
        // 1. 检查 Backend 是否自己实现了 undo:
        if ([active.backend respondsToSelector:@selector(undo:)]) {
            APPINE_LOG(@"[appine] Routing undo to backend's custom undo: method");
            #pragma clang diagnostic push
            #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            [active.backend performSelector:@selector(undo:) withObject:nil];
            #pragma clang diagnostic pop
            return;
        }

        // 2. 检查视图自带的 UndoManager
        NSUndoManager *undoMgr = nil;
        if (active.backend.view) {
            undoMgr = [active.backend.view undoManager];
        }

        APPINE_LOG(@"[appine] Backend view undoManager: %@, canUndo: %d", undoMgr, undoMgr ? [undoMgr canUndo] : 0);

        if (undoMgr && [undoMgr canUndo]) {
            APPINE_LOG(@"[appine] Executing undo on view's undoManager");
            [undoMgr undo];
            return;
        } else {
            APPINE_LOG(@"[appine] View's undoManager is nil or cannot undo right now.");
        }
    }

    // 3. 兜底逻辑
    APPINE_LOG(@"[appine] Falling back to global sendAction for undo:");
    [self focusAndSendAction:@selector(undo:)];
}
- (void)cut:(id)sender { (void)sender; [self focusAndSendAction:@selector(cut:)]; }
- (void)copy:(id)sender { (void)sender; [self focusAndSendAction:@selector(copy:)]; }
- (void)paste:(id)sender { (void)sender; [self focusAndSendAction:@selector(paste:)]; }
- (void)find:(id)sender {
    (void)sender;
    appine_set_active(YES);

    // 直接调用当前活跃 backend 的 toggleFindBar
    AppineState *state = appine_state();
    AppineTabItem *active = appine_find_tab(state.activeTabId);

    if (active && active.backend &&
        [active.backend respondsToSelector:@selector(toggleFindBar)]) {
        [active.backend toggleFindBar];
        APPINE_LOG(@"[appine] toggleFindBar called on backend");
    } else {
        APPINE_LOG(@"[appine] active backend does not support find bar");
    }
}

// PDF 的方向和正常是相反的, interesting...
- (BOOL)scrollPageDown:(id)sender {
    (void)sender;
    SEL sel = (appine_active_backend_kind() == AppineBackendKindPDF)
        ? @selector(scrollPageUp:)
        : @selector(scrollPageDown:);
    return [self sendScrollActionHandled:sel];
}
- (BOOL)scrollPageUp:(id)sender {
    (void)sender;
    SEL sel = (appine_active_backend_kind() == AppineBackendKindPDF)
        ? @selector(scrollPageDown:)
        : @selector(scrollPageUp:);
    return [self sendScrollActionHandled:sel];
}
- (BOOL)scrollLineDown:(id)sender {
    (void)sender;
    SEL sel = (appine_active_backend_kind() == AppineBackendKindPDF)
        ? @selector(scrollLineUp:)
        : @selector(scrollLineDown:);
    return [self sendScrollActionHandled:sel];
}
- (BOOL)scrollLineUp:(id)sender {
    (void)sender;
    SEL sel = (appine_active_backend_kind() == AppineBackendKindPDF)
        ? @selector(scrollLineDown:)
        : @selector(scrollLineUp:);
    return [self sendScrollActionHandled:sel];
}
- (BOOL)scrollToTop:(id)sender    { (void)sender; return [self sendScrollActionHandled:@selector(scrollToBeginningOfDocument:)]; }
- (BOOL)scrollToBottom:(id)sender { (void)sender; return [self sendScrollActionHandled:@selector(scrollToEndOfDocument:)]; }

- (void)tabChanged:(NSSegmentedControl *)sender {
    AppineState *state = appine_state();
    APPINE_LOG(@"tabChanged triggered. Selected segment: %ld", (long)sender.selectedSegment);
    if (sender.selectedSegment >= 0 && sender.selectedSegment < (NSInteger)state.tabs.count) {
        state.activeTabId = state.tabs[sender.selectedSegment].tabId;
        APPINE_LOG(@"Switching to tabId: %ld", (long)state.activeTabId);
        appine_attach_active_view();
    }
}
- (void)nextTab:(NSSegmentedControl *)sender {
    AppineState *state = appine_state();
    if (state.tabs.count < 2) return;
    AppineTabItem *active = appine_find_tab(state.activeTabId);
    NSInteger idx = [state.tabs indexOfObject:active];
    state.activeTabId = state.tabs[(idx + 1) % state.tabs.count].tabId;
    appine_attach_active_view();
}
- (void)prevTab:(NSSegmentedControl *)sender {
    AppineState *state = appine_state();
    if (state.tabs.count < 2) return;
    AppineTabItem *active = appine_find_tab(state.activeTabId);
    NSInteger idx = [state.tabs indexOfObject:active];
    state.activeTabId = state.tabs[(idx - 1 + state.tabs.count) % state.tabs.count].tabId;
    appine_attach_active_view();
}

- (void)findNext:(id)sender {
    (void)sender;
    appine_set_active(YES);

    AppineState *state = appine_state();
    AppineTabItem *active = appine_find_tab(state.activeTabId);

    // 注意这里是 findNext: 带冒号
    if (active && active.backend &&
        [active.backend respondsToSelector:@selector(findNext:)]) {
        #pragma clang diagnostic push
        #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        [active.backend performSelector:@selector(findNext:) withObject:nil];
        #pragma clang diagnostic pop
        APPINE_LOG(@"[appine] findNext: called on backend");
    }
}

- (void)findPrevious:(id)sender {
    (void)sender;
    appine_set_active(YES);

    AppineState *state = appine_state();
    AppineTabItem *active = appine_find_tab(state.activeTabId);

    // 注意这里是 findPrevious: 带冒号
    if (active && active.backend &&
        [active.backend respondsToSelector:@selector(findPrevious:)]) {
        #pragma clang diagnostic push
        #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        [active.backend performSelector:@selector(findPrevious:) withObject:nil];
        #pragma clang diagnostic pop
        APPINE_LOG(@"[appine] findPrevious: called on backend");
    }
}


@end

static AppineActionTarget *g_action_target = nil;


#pragma mark - Event Monitor
// ===========================================================================
// Globla Event Monitor
// ===========================================================================
static void appine_setup_global_event_monitor(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        // 同时监听 鼠标左键 和 键盘按下
        // NSEventMask mask = NSEventMaskLeftMouseDown | NSEventMaskKeyDown;
        NSEventMask mask = NSEventMaskLeftMouseDown | NSEventMaskKeyDown | NSEventMaskMouseMoved;
        [NSEvent addLocalMonitorForEventsMatchingMask:mask handler:^NSEvent * _Nullable(NSEvent * _Nonnull event) {

            // ------------------------------------------------
            // 拦截鼠标移动事件，用于恢复 Emacs 的边缘光标 (<->)
            // ------------------------------------------------
            if (event.type == NSEventTypeMouseMoved) {
                AppineState *state = appine_state();
                if (state.isActive && state.hostWindow && state.containerView) {
                    NSPoint loc = [state.containerView convertPoint:event.locationInWindow fromView:nil];
                    NSRect bounds = state.containerView.bounds;

                    // 如果鼠标悬停在 Appine 的边缘区域
                    if (loc.x <= 6.0 || loc.x >= bounds.size.width - 6.0 ||
                        loc.y <= 4.0 || loc.y >= bounds.size.height - 4.0) {

                        NSView *emacsView = appine_get_emacs_view();
                        if (emacsView && [emacsView respondsToSelector:@selector(mouseMoved:)]) {
                            // 强行抄送一份移动事件给 Emacs，触发 Emacs 内部的光标计算逻辑
                            [emacsView mouseMoved:event];
                        }
                        // 吞噬掉这个事件,彻底切断 PDFView 等收到移动事件的途径，防止 <-> 闪烁
                        return nil;
                    }
                }
                return event; // 不在边缘时，正常返回事件
            }


            // 调试：无条件打印所有键盘事件
            if (event.type == NSEventTypeKeyDown) {
                NSEventModifierFlags flags = event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;
                APPINE_LOG(@"[appine-debug-event] KeyDown RECEIVED - keyCode: %hu, chars: '%@', charsIgnoring: '%@', ctrl:%d opt:%d shift:%d cmd:%d",
                      event.keyCode,
                      event.characters,
                      event.charactersIgnoringModifiers,
                      (flags & NSEventModifierFlagControl) != 0,
                      (flags & NSEventModifierFlagOption) != 0,
                      (flags & NSEventModifierFlagShift) != 0,
                      (flags & NSEventModifierFlagCommand) != 0);
            }
            // ------------------------------------------------
            // 拦截键盘事件 (处理 Emacs 风格的 C-y, M-w 等)
            // 经过测试不同的 emacs 版本，Ctrl key的捕获基本没有问题
            // 但是 Meta 键有时候会被不同层捕获到，可能走不到这个 monitor 中。
            // ------------------------------------------------
            APPINE_LOG(@"envet.type: %lu, NSEventTypeKeyDown: %lu", event.type, NSEventTypeKeyDown);
            if (event.type == NSEventTypeKeyDown) {
                AppineState *state = appine_state();
                if (!state.containerView || !state.isActive || !state.hostWindow) {
                    return event;
                }
                if (state.isActive && state.hostWindow && state.hostWindow.firstResponder) {
                    NSResponder *responder = state.hostWindow.firstResponder;
                    BOOL isAppineFocused = NO;
                    if ([responder isKindOfClass:[NSView class]]) {
                        NSView *v = (NSView *)responder;
                        while (v) {
                            if (v == state.containerView) {
                                isAppineFocused = YES;
                                break;
                            }
                            v = v.superview;
                        }
                    }
                    APPINE_LOG(@"check isAppineFocused: %d", isAppineFocused);
                    if (isAppineFocused) {
                        NSEventModifierFlags flags = event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;
                        NSString *chars = event.charactersIgnoringModifiers.lowercaseString;

                        BOOL isCtrl = (flags & NSEventModifierFlagControl) != 0;
                        BOOL isOpt  = (flags & NSEventModifierFlagOption) != 0;
                        BOOL isShift = (flags & NSEventModifierFlagShift) != 0;

                        APPINE_LOG(@"check isCtrl: %d, isOpt: %d, isShift: %d, chars: %@", isCtrl, isOpt, isShift, chars);
                        // ----------------------------------------------------------
                        // 拦截 Emacs 前缀键 (C-x, C-c, C-h) 和全局键 (C-g, M-x)
                        // ----------------------------------------------------------
                        if ((isCtrl && ([chars isEqualToString:@"x"] ||
                                        [chars isEqualToString:@"c"] ||
                                        [chars isEqualToString:@"g"] ||
                                        [chars isEqualToString:@"h"])) ||
                            (isOpt  && [chars isEqualToString:@"x"])) {

                            // 寻找 EmacsMainView 尝试 superview
                            NSView *emacsView = appine_get_emacs_view();
                            if (emacsView) {
                                // 将 macOS 的键盘焦点强行还给 Emacs 主视图
                                [state.hostWindow makeFirstResponder:emacsView];
                            }
                            // 直接 return event，让系统自然地把按键分发给 Emacs
                            return event;
                        }

                        // ----------------------------------------------------------
                        // 拦截并映射到原生 Action (C-y, C-w, M-w, C-/, C-s)
                        // ----------------------------------------------------------
                        if (isCtrl && [chars isEqualToString:@"y"]) { [g_action_target paste:nil]; return nil; }
                        if (isCtrl && [chars isEqualToString:@"w"]) { [g_action_target cut:nil]; return nil; }
                        if (isOpt  && [chars isEqualToString:@"w"]) { [g_action_target copy:nil]; return nil; }
                        if (isCtrl && [chars isEqualToString:@"/"]) { [g_action_target undo:nil]; return nil; }
                        if (isCtrl && [chars isEqualToString:@"s"]) { [g_action_target find:nil]; return nil; }
                        if (isCtrl && [chars isEqualToString:@"f"]) { [g_action_target nextTab:nil]; return nil; }
                        if (isCtrl && [chars isEqualToString:@"b"]) { [g_action_target prevTab:nil]; return nil; }
                        // ==========================================================
                        // 3. 拦截滚动快捷键 (C-v, M-v, C-n, C-p, M-<, M->)
                        // ==========================================================

                        if (isCtrl && [chars isEqualToString:@"v"]) { return [g_action_target scrollPageDown:nil] ? nil:event; }
                        if (isOpt  && [chars isEqualToString:@"v"]) { return [g_action_target scrollPageUp:nil] ? nil:event; }
                        if (isCtrl && [chars isEqualToString:@"n"]) { return [g_action_target scrollLineDown:nil] ? nil:event; }
                        if (isCtrl && [chars isEqualToString:@"p"]) { return [g_action_target scrollLineUp:nil] ? nil:event; }

                        // M-< 和 M-> 在美式键盘上通常是 Option + Shift + , 和 Option + Shift + .
                        // charactersIgnoringModifiers 有时会受 Shift 影响，所以同时兼容逗号句号和尖括号
                        if (isOpt && isShift && ([chars isEqualToString:@","] || [chars isEqualToString:@"<"])) {
                            return [g_action_target scrollToTop:nil] ? nil: event;
                        }
                        if (isOpt && isShift && ([chars isEqualToString:@"."] || [chars isEqualToString:@">"])) {
                            return [g_action_target scrollToBottom:nil] ? nil:event;
                        }
                        // 如果按键没有被上面的逻辑拦截（比如普通的字母 f，或者在网页输入框打字），
                        // 且当前焦点在 Appine 内部，我们必须手动把事件发给 WKWebView，
                        // 然后返回 nil，防止 Emacs 拦截它！
                        if (state.hostWindow.firstResponder) {
                            [state.hostWindow.firstResponder keyDown:event];
                            APPINE_LOG(@"key send to current firstResponder: %@", [state.hostWindow.firstResponder className]);                                        return nil;
                        }
                    }
                }
                return event;
            }
            // ----------------------------------------------------------
            // 原有的鼠标点击逻辑 (绕过 Emacs 事件黑洞)
            // ----------------------------------------------------------
            NSView *hitView = nil;
            if (event.window && event.window.contentView) {
                hitView = [event.window.contentView hitTest:event.locationInWindow];
            }

            APPINE_LOG(@"[appine] GLOBAL CLICK at %@, hitTest view: %@, window: %@",
                NSStringFromPoint(event.locationInWindow), [hitView className], [event.window className]);

            if ([hitView isKindOfClass:[NSSegmentedControl class]]) {
                NSSegmentedControl *tabControl = (NSSegmentedControl *)hitView;
                NSPoint loc = [tabControl convertPoint:event.locationInWindow fromView:nil];
                NSInteger count = tabControl.segmentCount;
                if (count > 0) {
                    CGFloat width = tabControl.bounds.size.width / count;
                    NSInteger clickedIdx = (NSInteger)(loc.x / width);
                    if (clickedIdx >= 0 && clickedIdx < count && [tabControl isEnabledForSegment:clickedIdx]) {
                        tabControl.selectedSegment = clickedIdx;
                        if (tabControl.target && tabControl.action) {
                            #pragma clang diagnostic push
                            #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                            [tabControl.target performSelector:tabControl.action withObject:tabControl];
                            #pragma clang diagnostic pop
                        }
                    }
                }
                return nil;
            }
            else if ([hitView isKindOfClass:[NSButton class]]) {
                NSButton *btn = (NSButton *)hitView;
                if (btn.isEnabled) {
                    if (btn.target && btn.action) {
                        #pragma clang diagnostic push
                        #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                        [btn.target performSelector:btn.action withObject:btn];
                        #pragma clang diagnostic pop
                    }
                }
                return nil;
            }
            else if ([hitView isKindOfClass:[NSTextField class]] || [hitView isKindOfClass:[NSTextView class]]) {
                [event.window makeFirstResponder:hitView];
                return event;
            }

            return event;
        }];
    });
}

#pragma mark - Custom Container View

@interface AppineContainerView : NSView
@end

@implementation AppineContainerView
- (NSView *)hitTest:(NSPoint)point {
    NSPoint localPoint = [self convertPoint:point fromView:self.superview];
    NSRect bounds = self.bounds;

    if (!NSPointInRect(localPoint, bounds)) {
        return [super hitTest:point];
    }

    BOOL isEdge = (localPoint.x <= 6.0 || localPoint.x >= bounds.size.width - 6.0 ||
                   localPoint.y <= 4.0 || localPoint.y >= bounds.size.height - 4.0);

    if (isEdge) {
        // 如果点击在边缘，打印日志并穿透
        APPINE_LOG(@"[Appine Edge] hitTest edge detected at local: %@, returning nil to pass to Emacs", NSStringFromPoint(localPoint));
        return nil;
    }

    return [super hitTest:point];
}
@end

#pragma mark - UI Management

static void appine_ensure_container(void) {
    appine_setup_global_event_monitor(); // 启动全局事件追踪，后续可以加开关关闭？

    AppineState *state = appine_state();
    if (state.containerView) return;

    NSWindow *win = appine_target_window();
    if (!win) return;

    state.isActive = NO;
    state.hostWindow = win;
    g_action_target = [[AppineActionTarget alloc] init];

    state.containerView = [[AppineContainerView alloc] initWithFrame:state.targetRect];
    [win.contentView addSubview:state.containerView];

    if (@available(macOS 10.14, *)) {
        state.containerView.appearance = win.appearance;
    }

    state.toolbarView = appine_create_color_box(NSZeroRect, [NSColor controlBackgroundColor], NSViewWidthSizable | NSViewMinYMargin);
    state.toolbarStack = [NSStackView stackViewWithViews:@[]];
    state.toolbarStack.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    // TODO：这里可能还有点问题，排版还是都靠左边了，Active/Inactive 使用了坐标强制靠右。有空了再修复。
    state.toolbarStack.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [state.toolbarView addSubview:state.toolbarStack];
    [state.containerView addSubview:state.toolbarView];
    // 1. 左侧按钮组 (默认 addArrangedSubview 会加到 Leading 靠左区域)
    NSArray *leftBtns = @[@"Open File", @"New Tab", @"Close Tab"];
    NSArray *leftSels = @[@"openFile:", @"newTab:", @"closeTab:"];
    for (NSUInteger i = 0; i < leftBtns.count; i++) {
        NSButton *btn = [NSButton buttonWithTitle:leftBtns[i] target:g_action_target action:NSSelectorFromString(leftSels[i])];
        [btn setBezelStyle:NSBezelStyleRounded];
        [state.toolbarStack addArrangedSubview:btn];
    }

    // 2. 右侧编辑按钮组 (继续加到靠左区域)
    NSArray *rightBtns = @[@"Cut", @"Copy", @"Paste", @"Undo", @"Find"];
    NSArray *rightSels = @[@"cut:", @"copy:", @"paste:", @"undo:", @"find:"];
    for (NSUInteger i = 0; i < rightBtns.count; i++) {
        NSButton *btn = [NSButton buttonWithTitle:rightBtns[i] target:g_action_target action:NSSelectorFromString(rightSels[i])];
        [btn setBezelStyle:NSBezelStyleRounded];
        [state.toolbarStack addArrangedSubview:btn];
    }

    // 3. 状态指示标签（靠右区域）
    state.statusLabel = [NSTextField labelWithString:@"Inactive 🔘"];
    state.statusLabel.font = [NSFont systemFontOfSize:13 weight:NSFontWeightMedium];
    state.statusLabel.textColor = [NSColor secondaryLabelColor];
    // 允许左侧边距自动拉伸，使其在窗口缩放时始终吸附在右侧
    state.statusLabel.autoresizingMask = NSViewMinXMargin | NSViewMinYMargin | NSViewMaxYMargin;
    [state.toolbarView addSubview:state.statusLabel]; // 注意这里是 toolbarView

    state.tabBarView = appine_create_color_box(NSZeroRect, [NSColor windowBackgroundColor], NSViewWidthSizable);
    state.tabControl = [NSSegmentedControl segmentedControlWithLabels:@[] trackingMode:NSSegmentSwitchTrackingSelectOne target:g_action_target action:@selector(tabChanged:)];
    // 等宽分布
    if (@available(macOS 10.13, *)) {
        state.tabControl.segmentDistribution = NSSegmentDistributionFillEqually;
    }
    if (@available(macOS 10.15, *)) {
        state.tabControl.selectedSegmentBezelColor = [NSColor colorWithName:@"AppineTabColor" dynamicProvider:^NSColor * _Nonnull(NSAppearance * _Nonnull appearance) {
            if ([appearance.name containsString:@"Dark"]) {
                return [NSColor colorWithWhite:0.35 alpha:1.0]; // Dark 模式：0.35 的灰度，比底色亮，但不刺眼
            } else {
                return [NSColor whiteColor]; // Light 模式：纯白色，非常清晰
            }
        }];
    } else if (@available(macOS 10.14, *)) {
        state.tabControl.selectedSegmentBezelColor = [NSColor whiteColor]; // 降级处理
    }
    [[state.tabControl cell] setLineBreakMode:NSLineBreakByTruncatingTail];
    state.tabControl.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    [state.tabBarView addSubview:state.tabControl];
    [state.containerView addSubview:state.tabBarView];

    state.contentHostView = [[NSBox alloc] init];
    state.contentHostView.boxType = NSBoxCustom;
    // state.contentHostView.borderType = NSLineBorder; // 开启边框，用于显示 Active 状态
    state.contentHostView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable; // 允许宽度拉伸
    [state.containerView addSubview:state.contentHostView];

    state.inactiveOverlayView = [[AppineInactiveOverlayView alloc] init];
    [state.containerView addSubview:state.inactiveOverlayView];

    appine_apply_rect();
    appine_apply_visual_state();
    appine_restore_session_if_needed();
}

static void appine_apply_rect(void) {
    AppineState *state = appine_state();
    if (!state.containerView) return;

    [state.containerView setFrame:state.targetRect];
    NSRect bounds = state.containerView.bounds;

    CGFloat th = bounds.size.height >= kAppineToolbarHeight ? kAppineToolbarHeight : 0;
    CGFloat tbh = bounds.size.height >= (th + kAppineTabBarHeight) ? kAppineTabBarHeight : 0;
    CGFloat ch = MAX(0, bounds.size.height - th - tbh);

    [state.toolbarView setFrame:NSMakeRect(0, bounds.size.height - th, bounds.size.width, th)];
    [state.toolbarStack setFrame:NSMakeRect(6, 4, bounds.size.width - 12, th - 8)];

    if (state.statusLabel) {
        [state.statusLabel sizeToFit];
        CGFloat lblW = state.statusLabel.bounds.size.width;
        CGFloat lblH = state.statusLabel.bounds.size.height;
        // X 坐标 = 总宽度 - 标签宽度 - 12 (右边距)
        [state.statusLabel setFrame:NSMakeRect(bounds.size.width - lblW - 12, (th - lblH) / 2.0, lblW, lblH)];
    }
    [state.tabBarView setFrame:NSMakeRect(0, ch, bounds.size.width, tbh)];
    // NSBox 有内部 contentView 坐标偏移，必须用 tabBarView.frame 直接计算，而不是用 bounds
    CGFloat tabControlWidth = bounds.size.width - 12;
    [state.tabControl setFrame:NSMakeRect(6, 2, bounds.size.width - 12, tbh - 4)];
    // 严格限制每个 Segment 的宽度，防止拖动时被内容撑开
    if (state.tabs.count > 0) {
        // 计算每个 tab 的绝对平均宽度
        CGFloat segmentWidth = tabControlWidth / state.tabs.count;
        for (NSInteger i = 0; i < (NSInteger)state.tabs.count; i++) {
            [state.tabControl setWidth:segmentWidth forSegment:i];
        }
    }
    [state.contentHostView setFrame:NSMakeRect(0, 0, bounds.size.width, ch)];
    [state.inactiveOverlayView setFrame:bounds];
}

static void appine_apply_visual_state(void) {
    AppineState *state = appine_state();
    BOOL active = state.isActive;

    state.contentHostView.fillColor = [NSColor textBackgroundColor];
    state.contentHostView.borderWidth = 2.0;
    state.contentHostView.borderColor = active ? [NSColor keyboardFocusIndicatorColor] : [NSColor separatorColor];

    state.inactiveOverlayView.hidden = active;
    [state.inactiveOverlayView setNeedsDisplay:YES]; // 确保遮罩在状态切换时重绘

    // 根据 active 状态切换文字和颜色
    if (active) {
        state.statusLabel.stringValue = @"Active ☑️";
        state.statusLabel.textColor = [NSColor labelColor]; // 激活时用深色/亮色
    } else {
        state.statusLabel.stringValue = @"Inactive 🔘";
        state.statusLabel.textColor = [NSColor secondaryLabelColor]; // 非激活时变灰
    }

    for (NSView *v in state.toolbarStack.arrangedSubviews) {
        if ([v isKindOfClass:[NSButton class]]) {
            NSButton *btn = (NSButton *)v;
            btn.enabled = active && (btn.action != @selector(closeTab:) || state.tabs.count > 0);
        }
    }
}

// 保存当前所有 Tab 的路径
static void appine_save_session(void) {
    AppineState *state = appine_state();
    NSMutableArray *tabsData = [NSMutableArray array];
    for (AppineTabItem *tab in state.tabs) {
        NSString *pathToSave = tab.originalPath;

        // 如果是 Web，尝试获取当前的真实 URL（解决 Google 搜索参数丢失问题）
        if (tab.backend.kind == AppineBackendKindWeb) {
            @try {
                id webView = [(id)tab.backend valueForKey:@"webView"];
                NSURL *url = [webView valueForKey:@"URL"];
                if (url && url.absoluteString.length > 0) {
                    pathToSave = url.absoluteString;
                }
            } @catch (NSException *e) {}
        }

        if (pathToSave) {
            NSString *kindStr = @"unknown";
            if (tab.backend.kind == AppineBackendKindWeb) kindStr = @"web";
            else if (tab.backend.kind == AppineBackendKindPDF) kindStr = @"pdf";
            else if (tab.backend.kind == AppineBackendKindQuickLook) kindStr = @"quicklook";
            else if (tab.backend.kind == AppineBackendKindRss) kindStr = @"rss";

            [tabsData addObject:@{@"path": pathToSave, @"kind": kindStr}];
        }
    }
    [[NSUserDefaults standardUserDefaults] setObject:tabsData forKey:@"AppineLastSessionTabsData"];
}


// 冷启动时恢复上次的 Tab
static void appine_restore_session_if_needed(void) {
    static BOOL hasRestored = NO;
    if (hasRestored) return;
    hasRestored = YES;

    NSArray *savedItems = [[NSUserDefaults standardUserDefaults] arrayForKey:@"AppineLastSessionTabsData"];

    if (savedItems && savedItems.count > 0) {
        for (NSDictionary *item in savedItems) {
            if (![item isKindOfClass:[NSDictionary class]]) continue;

            NSString *savedPath = item[@"path"];
            NSString *kind = item[@"kind"];
            if (!savedPath) continue;

            id<AppineBackend> backend = nil;
            NSString *pathForBackend = savedPath;

            if ([savedPath hasPrefix:@"file:"]) {
                NSURL *url = [NSURL URLWithString:savedPath];
                if (url && url.path) pathForBackend = url.path;
            }

            if ([kind isEqualToString:@"rss"]) {
                backend = appine_create_rss_backend(pathForBackend);
            } else if ([kind isEqualToString:@"quicklook"]) {
                backend = appine_create_quicklook_backend(pathForBackend);
            } else if ([kind isEqualToString:@"web"]) {
                backend = appine_create_web_backend(savedPath);
            } else if ([kind isEqualToString:@"pdf"]) {
                backend = appine_create_pdf_backend(pathForBackend);
            } else {
                // 兜底
                if ([savedPath hasPrefix:@"http://"] || [savedPath hasPrefix:@"https://"]) {
                    backend = appine_create_web_backend(savedPath);
                } else {
                    backend = appine_create_backend_for_file(pathForBackend);
                }
            }

            if (backend) appine_add_tab(backend, savedPath);
        }
    }
}

static void appine_rebuild_tabs(void) {
    AppineState *state = appine_state();
    if (!state.tabControl) return;

    // 设置数量
    [state.tabControl setSegmentCount:state.tabs.count];
    NSInteger selectedIdx = -1;

    // 设置标题
    for (NSInteger i = 0; i < (NSInteger)state.tabs.count; i++) {
        AppineTabItem *item = state.tabs[i];

        NSString *title = item.backend.title;
        if (!title || title.length == 0) {
            title = [item.originalPath lastPathComponent];
        }
        if (!title || title.length == 0) {
            title = @"Loading...";
        }

        const NSUInteger kMaxTitleLength = 30;
        if (title.length > kMaxTitleLength) {
            title = [[title substringToIndex:kMaxTitleLength - 1] stringByAppendingString:@"…"];
        }
        [state.tabControl setLabel:title forSegment:i];
        if (item.tabId == state.activeTabId) selectedIdx = i;
    }

    if (selectedIdx >= 0) [state.tabControl setSelectedSegment:selectedIdx];

    // 在设置完内容后，再强制赋予 Frame。
    // 这会触发 NSSegmentedControl 内部的重新计算逻辑，把宽度均分给刚刚创建的 Segments
    if (state.containerView) {
        NSRect tabFrame = state.tabControl.frame;
        tabFrame.size.width = state.containerView.bounds.size.width - 12;
        state.tabControl.frame = tabFrame;
        if (state.tabs.count > 0) {
            CGFloat segmentWidth = tabFrame.size.width / state.tabs.count;
            for (NSInteger i = 0; i < (NSInteger)state.tabs.count; i++) {
                [state.tabControl setWidth:segmentWidth forSegment:i];
            }
        }
    }

    // 强制要求系统在下一个 UI 周期立刻布局和重绘
    [state.tabControl setNeedsLayout:YES];
    [state.tabControl setNeedsDisplay:YES];

    // 异步的强制重绘，防止首次加载空白
    dispatch_async(dispatch_get_main_queue(), ^{
        [state.tabControl setNeedsLayout:YES];
        [state.tabControl layoutSubtreeIfNeeded];
        [state.tabControl setNeedsDisplay:YES];
        [state.tabControl display];
    });

    appine_save_session();
}

static void appine_attach_active_view(void) {
    AppineState *state = appine_state();
    if (!state.contentHostView) return;

    // NSBox 不能直接清空 subviews，必须操作它的 contentView
    NSView *targetContainer = state.contentHostView.contentView;
    if (!targetContainer) targetContainer = state.contentHostView; // 兜底防空

    // 清空旧的视图
    for (NSView *v in targetContainer.subviews) {
        [v removeFromSuperview];
    }

    AppineTabItem *active = appine_find_tab(state.activeTabId);
    if (active && active.backend.view) {
        NSView *v = active.backend.view;
        [v setFrame:targetContainer.bounds];
        [v setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
        [targetContainer addSubview:v]; // 添加到 contentView 中
    }

    appine_rebuild_tabs();
    // 保险：对齐焦点
    appine_restore_focus_if_active();
}

static void appine_set_active(BOOL active) {
    AppineState *state = appine_state();

    BOOL changed = (state.isActive != active);
    state.isActive = active;

    if (changed) {
        APPINE_LOG(@"State changing to active: %d", active);
        appine_apply_visual_state();
    }

    if (active) {
        // 只要要求激活，就检查当前焦点是否在 Appine 的容器视图内
        NSResponder *responder = state.hostWindow.firstResponder;
        BOOL isAppineFocused = NO;
        if ([responder isKindOfClass:[NSView class]]) {
            NSView *v = (NSView *)responder;
            while (v) {
                if (v == state.containerView) {
                    isAppineFocused = YES;
                    break;
                }
                v = v.superview;
            }
        }

        // 如果焦点不在 Appine 内部（比如被 C-x 临时借给了 Emacs），则强制抢回焦点
        if (!isAppineFocused) {
            AppineTabItem *tab = appine_find_tab(state.activeTabId);
            if (tab && tab.backend.view) {
                NSView *focusTarget = appine_find_focus_target(tab.backend.view);
                APPINE_LOG(@"Forcing FirstResponder to target view: %@", [focusTarget className]);
                [state.hostWindow makeFirstResponder:focusTarget];
            }
        }
    } else {
        if (changed) {
            APPINE_LOG(@"Yielding focus. Current FirstResponder is: %@", [state.hostWindow.firstResponder className]);
            // 把 macOS 的键盘焦点还给 Emacs
            NSView *emacsView = appine_get_emacs_view();
            if (emacsView) {
                [state.hostWindow makeFirstResponder:emacsView];
            }
        }
    }
}

static void appine_add_tab(id<AppineBackend> backend, NSString *originalPath) {
    AppineState *state = appine_state();
    AppineTabItem *item = [[AppineTabItem alloc] init];
    item.tabId = state.nextTabId++;
    item.backend = backend;
    item.originalPath = originalPath;
    [state.tabs addObject:item];
    state.activeTabId = item.tabId;
    appine_attach_active_view();
    appine_set_active(YES);
}

void appine_core_add_web_tab(NSString *urlString) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (urlString) {
          appine_add_tab(appine_create_web_backend(urlString), urlString);
        }
    });
}

#pragma mark - C API Exports

int appine_core_open_web_in_rect(const char *url, int x, int y, int w, int h) {
    NSString *initialUrlString = url ? [NSString stringWithUTF8String:url] : @"https://google.com";

    dispatch_async(dispatch_get_main_queue(), ^{
        appine_state().targetRect = NSMakeRect(x, y, w, h);
        appine_ensure_container();

        // 去除首尾空格
        NSString *urlString = [initialUrlString stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        // 如果为空，说明 AppineLastSessionTabsData 有内容，不需要打开新的内容。
        if (urlString.length == 0) {
            return;
        }
        NSURL *nsUrl = nil;

        // 【guess 1】：如果是绝对路径，直接转为 file:// 协议
        if ([urlString hasPrefix:@"/"] || [urlString hasPrefix:@"~"]) {
            // 自动将 ~/Downloads 展开为 /Users/username/Downloads
            NSString *expandedPath = [urlString stringByExpandingTildeInPath];
            // 使用 fileURLWithPath 自动处理路径中的空格和特殊字符（比手动拼 file:// 更安全）
            nsUrl = [NSURL fileURLWithPath:expandedPath];
            urlString = nsUrl.absoluteString; // 同步更新 urlString
        } else {
            nsUrl = [NSURL URLWithString:urlString];
        }

        // 【guess 2】：如果没有协议头，或者是无效 URL（比如包含空格导致 nsUrl 为 nil）
        if (!nsUrl || !nsUrl.scheme) {
            BOOL hasSpace = [urlString containsString:@" "];
            BOOL hasDot = [urlString containsString:@"."];
            BOOL isLocalhost = [urlString hasPrefix:@"localhost"];

            if (hasSpace || (!hasDot && !isLocalhost)) {
                // 包含空格，或者没有点号（且不是 localhost），视为搜索引擎 Query
                NSString *encodedQuery = [urlString stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]];
                urlString = [NSString stringWithFormat:@"https://www.google.com/search?q=%@", encodedQuery];
            } else {
                // 类似 "github.com" 的域名。
                // 默认补全 http://，现代网站会自动 301 跳转到 https://，而纯 http 网站也能正常打开
                urlString = [@"http://" stringByAppendingString:urlString];
            }
            nsUrl = [NSURL URLWithString:urlString];
        }

        id<AppineBackend> backend = nil;

        // 1. 如果是 file:// 协议，复用已有的文件路由逻辑
        if ([nsUrl.scheme caseInsensitiveCompare:@"file"] == NSOrderedSame) {
            backend = appine_create_backend_for_file(nsUrl.path);
        }
        else {
            // 手动判断常见的 Web 协议，避免引入 WebKit 头文件导致耦合
            NSArray *webSchemes = @[@"http", @"https", @"data", @"about", @"blob"];

            // 2. 如果是 WebKit 支持的常规协议
            if ([webSchemes containsObject:nsUrl.scheme.lowercaseString]) {
                backend = appine_create_web_backend(urlString);
            }
            // 3. 兜底：交给 macOS 系统打开（如 mailto:, tg:// 等）
            else {
                APPINE_LOG(@"[Appine] WebKit 不支持该协议 '%@'，交由 macOS 系统打开", nsUrl.scheme);
                [[NSWorkspace sharedWorkspace] openURL:nsUrl];
            }
        }

        if (backend) {
          appine_add_tab(backend, urlString);
        }
    });
    return 0;
}

// TODO: delete this function
int appine_core_open_file_in_rect(const char *path, int x, int y, int w, int h) {
    NSString *filePath = path ? [NSString stringWithUTF8String:path] : @"";
    dispatch_async(dispatch_get_main_queue(), ^{
        appine_state().targetRect = NSMakeRect(x, y, w, h);
        appine_ensure_container();

        id<AppineBackend> backend = appine_create_backend_for_file(filePath);
        if (backend) {
          appine_add_tab(backend, filePath);
        }
    });
    return 0;
}

int appine_core_move_resize(int x, int y, int w, int h) {
    dispatch_async(dispatch_get_main_queue(), ^{
        // 获取当前的尺寸
        NSRect currentRect = appine_state().targetRect;

        // 如果 w 或 h <= 0，则复用之前的尺寸
        CGFloat newW = (w > 0) ? w : currentRect.size.width;
        CGFloat newH = (h > 0) ? h : currentRect.size.height;

        // 如果之前也没有尺寸，给个保底值
        if (newW <= 0) newW = 800;
        if (newH <= 0) newH = 600;

        appine_state().targetRect = NSMakeRect(x, y, newW, newH);
        appine_apply_rect();
    });
    return 0;
}

void appine_core_update_tabs(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        appine_rebuild_tabs();
    });
}

int appine_core_close_active_tab(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        AppineState *state = appine_state();
        AppineTabItem *active = appine_find_tab(state.activeTabId);
        if (active) {
            // cleanup
            if ([active.backend respondsToSelector:@selector(cleanup)]) {
                [active.backend cleanup];
            }
            NSInteger idx = [state.tabs indexOfObject:active];
            [state.tabs removeObject:active];
            if (state.tabs.count > 0) {
                state.activeTabId = state.tabs[MIN(idx, (NSInteger)state.tabs.count - 1)].tabId;
            } else {
                state.activeTabId = -1;
            }
            appine_attach_active_view();
            appine_apply_visual_state();
        }
    });
    return 0;
}

int appine_core_select_next_tab(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        AppineState *state = appine_state();
        if (state.tabs.count < 2) return;
        AppineTabItem *active = appine_find_tab(state.activeTabId);
        NSInteger idx = [state.tabs indexOfObject:active];
        state.activeTabId = state.tabs[(idx + 1) % state.tabs.count].tabId;
        appine_attach_active_view();
    });
    return 0;
}

int appine_core_select_prev_tab(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        AppineState *state = appine_state();
        if (state.tabs.count < 2) return;
        AppineTabItem *active = appine_find_tab(state.activeTabId);
        NSInteger idx = [state.tabs indexOfObject:active];
        state.activeTabId = state.tabs[(idx - 1 + state.tabs.count) % state.tabs.count].tabId;
        appine_attach_active_view();
    });
    return 0;
}

int appine_core_set_active(int active) {
    dispatch_async(dispatch_get_main_queue(), ^{
        appine_set_active(active != 0);
    });
    return 0;
}

int appine_core_focus(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        appine_set_active(YES);
    });
    return 0;
}

int appine_core_unfocus(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        appine_set_active(NO);
    });
    return 0;
}

int appine_core_perform_action(const char *action_name) {
    NSString *action = action_name ? [NSString stringWithUTF8String:action_name] : nil;
    if (!action) return 0;
    dispatch_async(dispatch_get_main_queue(), ^{
        appine_set_active(YES);
        SEL sel = NSSelectorFromString([action stringByAppendingString:@":"]);

        BOOL handled = NO;

        // 1. 优先检查自定义 g_action_target 是否实现了该方法 (如 newTab:, openFile:, find:)
        if (g_action_target && [g_action_target respondsToSelector:sel]) {
            #pragma clang diagnostic push
            #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            [g_action_target performSelector:sel withObject:nil];
            #pragma clang diagnostic pop
            handled = YES;
        }
        // 2. 否则发送给 macOS 响应链（处理标准的 copy:, paste: 等原生未被拦截的 action）
        else if ([NSApp sendAction:sel to:nil from:nil]) {
            handled = YES;
        }

        if (!handled) {
            APPINE_LOG(@"[appine] action not handled: %@", action);
        } else {
            APPINE_LOG(@"[appine] action handled succ: %@", action);
        }
    });
    return 0;
}

int appine_core_close(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        AppineState *state = appine_state();

        // 1. 先把焦点还给 Emacs
        if (state.hostWindow) {
            NSView *emacsView = appine_get_emacs_view();
            if (emacsView) {
                [state.hostWindow makeFirstResponder:emacsView];
            }
        }

        // 2. 重置所有状态
        state.isActive = NO;

        // 3. 移除视图
        [state.containerView removeFromSuperview];
        state.containerView = nil;
        state.toolbarView = nil;
        state.toolbarStack = nil;
        state.tabBarView = nil;
        state.tabControl = nil;
        state.contentHostView = nil;
        state.inactiveOverlayView = nil;

        // 4. 清空 tabs
        for (AppineTabItem *item in state.tabs) {
            if ([item.backend respondsToSelector:@selector(cleanup)]) {
                [item.backend cleanup];
            }
        }
        [state.tabs removeAllObjects];
        state.activeTabId = -1;

        // 5. 解除 hostWindow 引用
        state.hostWindow = nil;

        APPINE_LOG(@"appine_core_close: all state reset, container removed.");
    });
    return 0;
}

// ===========================================================================
// Web 专属控制 API
// ===========================================================================
int appine_core_web_go_forward(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        AppineState *state = appine_state();
        AppineTabItem *active = appine_find_tab(state.activeTabId);

        // 动态检查当前的 backend 是否实现了 goForward: 方法
        if (active && [active.backend respondsToSelector:@selector(goForward:)]) {
            #pragma clang diagnostic push
            #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            [active.backend performSelector:@selector(goForward:) withObject:nil];
            #pragma clang diagnostic pop
            appine_restore_focus_if_active();
        }
    });

    return 0;
}

int appine_core_web_go_back(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        AppineState *state = appine_state();
        AppineTabItem *active = appine_find_tab(state.activeTabId);

        // 动态检查当前的 backend 是否实现了 goBack: 方法
        if (active && [active.backend respondsToSelector:@selector(goBack:)]) {
            #pragma clang diagnostic push
            #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            [active.backend performSelector:@selector(goBack:) withObject:nil];
            #pragma clang diagnostic pop
            appine_restore_focus_if_active();
        }
    });
    return 0;
}

int appine_core_web_reload(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        AppineState *state = appine_state();
        AppineTabItem *active = appine_find_tab(state.activeTabId);

        // 动态检查当前的 backend 是否实现了 reload: 方法
        if (active && [active.backend respondsToSelector:@selector(reload:)]) {
            #pragma clang diagnostic push
            #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            [active.backend performSelector:@selector(reload:) withObject:nil];
            #pragma clang diagnostic pop
            appine_restore_focus_if_active();
        }
    });
    return 0;
}

// ===========================================================================
// rss api
// ===========================================================================
int appine_core_open_rss_in_rect(const char *path, int x, int y, int w, int h) {
    NSString *nsPath = path ? [NSString stringWithUTF8String:path] : nil;
    dispatch_async(dispatch_get_main_queue(), ^{
        // 1. 记录 Emacs 传过来的坐标和尺寸
        appine_state().targetRect = NSMakeRect(x, y, w, h);

        // 2. 确保底层容器被正确创建并挂载到 Emacs 窗口上
        appine_ensure_container();

        // 3. 创建并添加 RSS Backend
        id<AppineBackend> backend = appine_create_rss_backend(nsPath);
        if (backend) {
          appine_add_tab(backend, nsPath);
          appine_restore_focus_if_active();
        }
    });
    return 0;
}

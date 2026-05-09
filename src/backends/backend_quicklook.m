/*
 * Filename: backend_quicklook.m
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
#import <Cocoa/Cocoa.h>
#import <Quartz/Quartz.h>
#import "appine_backend.h"

// ===========================================================================
// 自定义 QLPreviewView 子类，处理重新挂载时的刷新逻辑
// ===========================================================================
@interface AppineQLPreviewView : QLPreviewView
@end

@implementation AppineQLPreviewView
- (void)viewDidMoveToSuperview {
    [super viewDidMoveToSuperview];
    // 当视图被重新添加到父视图 (切换 Tab 恢复) 时，重新赋值 previewItem 触发渲染
    if (self.superview) {
        id<QLPreviewItem> item = self.previewItem;
        if (item) {
            self.previewItem = nil;
            self.previewItem = item;
        }
    }
}
@end

// ===========================================================================

@interface AppineQuickLookBackend : NSObject <AppineBackend>
@property(nonatomic, strong) AppineQLPreviewView *previewView;
@property(nonatomic, copy) NSString *title;
@end

@implementation AppineQuickLookBackend

- (AppineBackendKind)kind {
    return AppineBackendKindQuickLook;
}

- (instancetype)initWithPath:(NSString *)path {
    if (self = [super init]) {
        _title = [path lastPathComponent] ?: @"Preview";

        // 使用自定义子类初始化
        _previewView = [[AppineQLPreviewView alloc] initWithFrame:NSZeroRect style:QLPreviewViewStyleNormal];
        _previewView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

        // NSURL 默认实现了 QLPreviewItem 协议
        NSURL *fileURL = [NSURL fileURLWithPath:path];
        if (fileURL) {
            _previewView.previewItem = (id<QLPreviewItem>)fileURL;
        }
    }
    return self;
}

- (NSView *)view {
    return self.previewView;
}

- (void)performAction:(NSString *)action {
    SEL sel = NSSelectorFromString([action stringByAppendingString:@":"]);
    [NSApp sendAction:sel to:self.previewView from:nil];
}

@end

// C API export
id<AppineBackend> appine_create_quicklook_backend(NSString *path) {
    return [[AppineQuickLookBackend alloc] initWithPath:path];
}

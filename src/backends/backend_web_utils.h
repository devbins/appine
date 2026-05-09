/*
 * Filename: backend_web_uitls.h
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

#import <Foundation/Foundation.h>
#import <WebKit/WebKit.h>

// ===========================================================================
// 专门用于接收 JS 消息的共享 Handler
// ===========================================================================
@interface AppineSharedScriptMessageHandler : NSObject <WKScriptMessageHandler>
+ (instancetype)sharedHandler;
@end

// ===========================================================================
// WebView Plugin System (Shared)
// ===========================================================================

// 为 WKWebViewConfiguration 统一注入 JS 插件系统
// 注意：内部会自动使用 AppineSharedScriptMessageHandler 接收消息，Backend 无需关心
void appine_setup_webview_plugins(WKWebViewConfiguration *config);

// 清理 WKWebViewConfiguration 中的消息代理，防止内存泄漏
void appine_cleanup_webview_plugins(WKWebViewConfiguration *config);

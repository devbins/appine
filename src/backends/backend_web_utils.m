/*
 * Filename: backend_web_uitls.m
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

#import "backend_web_utils.h"
#import "appine_core.h"
#import <dlfcn.h>

// ===========================================================================
// 实现共享的 Message Handler
// ===========================================================================
@implementation AppineSharedScriptMessageHandler

+ (instancetype)sharedHandler {
    static AppineSharedScriptMessageHandler *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[self alloc] init];
    });
    return instance;
}


// ==========================================
// 接收来自 JS 的 console.log
// ==========================================
- (void)userContentController:(WKUserContentController *)userContentController didReceiveScriptMessage:(WKScriptMessage *)message {
    if ([message.name isEqualToString:@"appineLog"]) {
        APPINE_LOG(@"[Appine-JS] %@", message.body);
    } 
    else if ([message.name isEqualToString:@"appineSaveData"]) {
        NSDictionary *body = message.body;
        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];

        if (body[@"ap_cfg"]) {
            [defaults setObject:body[@"ap_cfg"] forKey:@"ap_cfg"];
        }
        if (body[@"ap_sess"]) {
            [defaults setObject:body[@"ap_sess"] forKey:@"ap_sess"];
        }

        // 同步到磁盘
        [defaults synchronize];
        APPINE_LOG(@"[Appine-Plugin] ✅ 全局配置已保存到 NSUserDefaults");
    }
}

@end


// ===========================================================================
// WebView Plugin System (Shared)
// ===========================================================================

void appine_setup_webview_plugins(WKWebViewConfiguration *config) {
    // 1. 获取共享的 handler
    id<WKScriptMessageHandler> handler = [AppineSharedScriptMessageHandler sharedHandler];
    
    // 2. 注册消息通道 (使用共享 handler)
    [config.userContentController addScriptMessageHandler:handler name:@"appineLog"];
    [config.userContentController addScriptMessageHandler:handler name:@"appineSaveData"];

    // 3. 注入基础的 console.log 劫持和错误捕获
    NSString *debugJS = @"\
        const origLog = console.log;\n\
        console.log = function(...args) {\n\
            origLog.apply(console, args);\n\
            const msg = args.map(a => typeof a === 'object' ? JSON.stringify(a) : String(a)).join(' ');\n\
            window.webkit.messageHandlers.appineLog.postMessage(msg);\n\
        };\n\
        window.addEventListener('error', function(e) {\n\
            console.log('❌ [Appine-JS-Error] 捕获到页面错误:', e.message, '行号:', e.lineno);\n\
        });\n\
    ";
    WKUserScript *debugScript = [[WKUserScript alloc] initWithSource:debugJS injectionTime:WKUserScriptInjectionTimeAtDocumentStart forMainFrameOnly:YES];
    [config.userContentController addUserScript:debugScript];

    // 4. 动态获取 dylib 路径以定位插件目录
    Dl_info info;
    NSString *appineDir = nil;
    if (dladdr((const void *)&appine_setup_webview_plugins, &info) != 0) {
        appineDir = [[NSString stringWithUTF8String:info.dli_fname] stringByDeletingLastPathComponent];
    } else {
        appineDir = [@"~/.emacs.d/straight/repos/appine" stringByExpandingTildeInPath];
    }

    NSString *extensionDir = [appineDir stringByAppendingPathComponent:@"browser-extension"];
    NSString *pluginsDir = [extensionDir stringByAppendingPathComponent:@"plugins"];

    // 5. 注入 utils.js
    NSString *utilsJS = [NSString stringWithContentsOfFile:[extensionDir stringByAppendingPathComponent:@"utils.js"] encoding:NSUTF8StringEncoding error:nil];
    if (utilsJS) {
        [config.userContentController addUserScript:[[WKUserScript alloc] initWithSource:utilsJS injectionTime:WKUserScriptInjectionTimeAtDocumentStart forMainFrameOnly:YES]];
    }

    // 6. 注入 content.js 及各个插件
    NSString *contentJS = [NSString stringWithContentsOfFile:[extensionDir stringByAppendingPathComponent:@"content.js"] encoding:NSUTF8StringEncoding error:nil];
    if (contentJS) {
        [config.userContentController addUserScript:[[WKUserScript alloc] initWithSource:contentJS injectionTime:WKUserScriptInjectionTimeAtDocumentEnd forMainFrameOnly:YES]];

        NSArray *plugins = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:pluginsDir error:nil];
        for (NSString *pluginName in plugins) {
            if ([pluginName hasPrefix:@"."]) continue; // 忽略隐藏文件如 .DS_Store
            
            NSString *pluginJS = [NSString stringWithContentsOfFile:[NSString stringWithFormat:@"%@/%@/index.js", pluginsDir, pluginName] encoding:NSUTF8StringEncoding error:nil];
            if (pluginJS) {
                // 将 ES6 的 export default 替换为 return，以便通过立即执行函数(IIFE)获取对象
                NSString *modifiedJS = [pluginJS stringByReplacingOccurrencesOfString:@"export default" withString:@"return"];
                NSString *pluginInjectionJS = [NSString stringWithFormat:@"{ try { const pluginObj = (function() {\n%@\n})(); window.PluginLoader.register(pluginObj); } catch(e) { console.log('[Appine-Plugin] ❌ Error: ' + e); } }", modifiedJS];
                
                [config.userContentController addUserScript:[[WKUserScript alloc] initWithSource:pluginInjectionJS injectionTime:WKUserScriptInjectionTimeAtDocumentEnd forMainFrameOnly:YES]];
            }
        }
    } else {
        APPINE_LOG(@"[Appine-Plugin] ⚠️ 未找到 content.js，请检查路径: %@", extensionDir);
    }
}

void appine_cleanup_webview_plugins(WKWebViewConfiguration *config) {
    [config.userContentController removeScriptMessageHandlerForName:@"appineLog"];
    [config.userContentController removeScriptMessageHandlerForName:@"appineSaveData"];
}


/*
 * Filename: backend_rss.m
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

#import "appine_core.h"
#import "appine_backend.h"
#import "backend_web_utils.h"
#import <WebKit/WebKit.h>
#import <QuartzCore/QuartzCore.h>
#import <sqlite3.h>

#pragma mark - Models

@interface RssNode : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *url;
@property (nonatomic, strong) NSMutableArray<RssNode *> *children;
@property (nonatomic, weak) RssNode *parent;
@property (nonatomic, assign) BOOL isSpecialUnread;
@property (nonatomic, assign) BOOL isSpecialStarred;
- (NSString *)orgFilePath;
- (NSInteger)unreadCount;
@end

@interface RssArticle : NSObject
@property (nonatomic, copy) NSString *articleId;
@property (nonatomic, copy) NSString *feedUrl;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *summary;
@property (nonatomic, copy) NSString *content;
@property (nonatomic, copy) NSString *link;
@property (nonatomic, copy) NSString *pubDate;
@property (nonatomic, strong) NSDate *parsedDate;
@property (nonatomic, assign) BOOL isRead;
@property (nonatomic, assign) BOOL isStarred;
@property (nonatomic, copy) NSString *orgFilePath;
@end

#pragma mark - Database Manager (SQLite)

@interface RssDatabase : NSObject
@property (nonatomic, assign) sqlite3 *db;
+ (instancetype)shared;
- (NSInteger)totalUnreadCount;
- (NSInteger)unreadCountForFeed:(NSString *)feedUrl;
- (NSArray<RssArticle *> *)allUnreadArticles;
- (void)setArticleReadStatus:(NSString *)articleId isRead:(BOOL)isRead;
- (void)saveArticle:(RssArticle *)article;
- (NSArray<RssArticle *> *)articlesForFeed:(NSString *)feedUrl;
- (NSInteger)totalStarredCount;
- (NSArray<RssArticle *> *)allStarredArticles;
- (void)toggleStarForArticle:(NSString *)articleId starred:(BOOL)isStarred;
@end

static NSString *g_rss_work_path = nil; // 全局工作目录

@implementation RssNode
- (instancetype)init { if (self = [super init]) { _children = [NSMutableArray array]; } return self; }

// 根据父节点层级，自动生成目录和文件路径
- (NSString *)orgFilePath {
    NSMutableArray *parts = [NSMutableArray array];
    RssNode *curr = self.parent;
    while (curr && curr.parent) { // 向上遍历，忽略最顶层的 "Subscriptions" 根节点
        if (![curr.name isEqualToString:@"Subscriptions"]) {
            [parts insertObject:curr.name atIndex:0];
        }
        curr = curr.parent;
    }

    NSString *dir = [g_rss_work_path stringByAppendingPathComponent:@"appine-rss/org_rss_data"];

    for (NSString *part in parts) {
        NSString *safePart = [part stringByReplacingOccurrencesOfString:@"/" withString:@"-"];
        dir = [dir stringByAppendingPathComponent:safePart];
    }

    // 自动创建多级目录
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];

    NSString *safeName = [self.name stringByReplacingOccurrencesOfString:@"/" withString:@"-"];
    return [[dir stringByAppendingPathComponent:safeName] stringByAppendingPathExtension:@"org"];
}

- (NSInteger)unreadCount {
    if (self.isSpecialUnread) return [[RssDatabase shared] totalUnreadCount];
    if (self.isSpecialStarred) return [[RssDatabase shared] totalStarredCount];
    if (self.url) return [[RssDatabase shared] unreadCountForFeed:self.url];
    NSInteger count = 0;
    for (RssNode *child in self.children) count += [child unreadCount];
    return count;
}

@end

@implementation RssArticle
- (NSDate *)parsedDate {
    if (!_parsedDate) {
        if (self.pubDate.length > 0) {
            static NSDataDetector *detector = nil;
            static dispatch_once_t onceToken;
            dispatch_once(&onceToken, ^{
                detector = [NSDataDetector dataDetectorWithTypes:NSTextCheckingTypeDate error:nil];
            });
            NSTextCheckingResult *match = [detector firstMatchInString:self.pubDate options:0 range:NSMakeRange(0, self.pubDate.length)];
            _parsedDate = match.date;
        }
        // 如果解析失败或没有日期，给一个极小的值，让它排在最后
        if (!_parsedDate) {
            _parsedDate = [NSDate distantPast];
        }
    }
    return _parsedDate;
}
@end

#pragma mark - Database Manager (SQLite)

@implementation RssDatabase
+ (instancetype)shared {
    static RssDatabase *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ instance = [[RssDatabase alloc] init]; });
    return instance;
}

- (instancetype)init {
    self = [super init];
    return self;
}

// 动态设置数据库路径
- (void)setupDatabase {
    if (_db) return; // 已经初始化过了

    NSString *dir = [g_rss_work_path stringByAppendingPathComponent:@"appine-rss/db"];
    NSError *error;
    if (![[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:&error]) {
        APPINE_LOG(@"[Appine RSS] ⚠️ 创建数据库目录失败: %@", error);
    }

    NSString *dbPath = [dir stringByAppendingPathComponent:@"rss.sqlite"];
    APPINE_LOG(@"[Appine RSS] 📂 数据库路径: %@", dbPath);

    if (sqlite3_open([dbPath UTF8String], &_db) == SQLITE_OK) {
        APPINE_LOG(@"[Appine RSS] ✅ 数据库打开成功");
        [self createTables];
    } else {
        APPINE_LOG(@"[Appine RSS] ❌ 数据库打开失败: %s", sqlite3_errmsg(_db));
    }
}

- (void)createTables {
    const char *sql = "CREATE TABLE IF NOT EXISTS articles ("
                      "id TEXT PRIMARY KEY, feed_url TEXT, title TEXT, summary TEXT, "
                      "content TEXT, link TEXT, pub_date TEXT, is_read INTEGER);";
    sqlite3_exec(_db, sql, NULL, NULL, NULL);
    // 创建索引提升查询速度
    sqlite3_exec(_db, "CREATE INDEX IF NOT EXISTS idx_is_read ON articles(is_read);", NULL, NULL, NULL);
    sqlite3_exec(_db, "ALTER TABLE articles ADD COLUMN is_starred INTEGER DEFAULT 0;", NULL, NULL, NULL);
}

- (void)saveArticle:(RssArticle *)article {
    const char *sql = "INSERT OR IGNORE INTO articles (id, feed_url, title, summary, content, link, pub_date, is_read) VALUES (?, ?, ?, ?, ?, ?, ?, ?)";
    sqlite3_stmt *stmt;
    if (sqlite3_prepare_v2(_db, sql, -1, &stmt, NULL) == SQLITE_OK) {
        // 优先使用解析到的 articleId，如果没有再退化使用 link
        NSString *uniqueId = article.articleId.length > 0 ? article.articleId : article.link;
        sqlite3_bind_text(stmt, 1, [uniqueId UTF8String], -1, SQLITE_TRANSIENT);
        sqlite3_bind_text(stmt, 2, [article.feedUrl UTF8String], -1, SQLITE_TRANSIENT);
        sqlite3_bind_text(stmt, 3, [article.title UTF8String], -1, SQLITE_TRANSIENT);
        sqlite3_bind_text(stmt, 4, [article.summary UTF8String], -1, SQLITE_TRANSIENT);
        sqlite3_bind_text(stmt, 5, [article.content UTF8String], -1, SQLITE_TRANSIENT);
        sqlite3_bind_text(stmt, 6, [article.link UTF8String], -1, SQLITE_TRANSIENT);
        sqlite3_bind_text(stmt, 7, [article.pubDate UTF8String], -1, SQLITE_TRANSIENT);
        sqlite3_bind_int(stmt, 8, article.isRead ? 1 : 0);
        sqlite3_step(stmt);

        if (sqlite3_changes(_db) > 0 && article.orgFilePath) {
            NSString *orgContent = [NSString stringWithFormat:@"\n* %@\n:PROPERTIES:\n:ID: %@\n:PUB_DATE: %@\n:LINK: %@\n%@%@:END:\n\n%@\n",                                          article.title ?: @"Untitled",
                                    uniqueId,
                                    article.pubDate ?: @"",
                                    article.link ?: @"",
                                    article.isStarred ? @":STARRED: 1\n" : @"",
                                    article.isRead ? @":IS_READ: 1\n" : @"",
                                    article.content ?: article.summary ?: @""];

            NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:article.orgFilePath];
            if (!handle) {
                // 文件不存在，直接创建并写入
                [orgContent writeToFile:article.orgFilePath atomically:YES encoding:NSUTF8StringEncoding error:nil];
            } else {
                // 文件已存在，追加到末尾
                [handle seekToEndOfFile];
                [handle writeData:[orgContent dataUsingEncoding:NSUTF8StringEncoding]];
                [handle closeFile];
            }
        }
    }

    sqlite3_finalize(stmt);
}

- (NSArray<RssArticle *> *)allUnreadArticles {
    NSMutableArray *results = [NSMutableArray array];
    const char *sql = "SELECT id, title, summary, content, link, pub_date, is_read, feed_url, is_starred FROM articles WHERE is_read = 0 ORDER BY pub_date DESC";
    sqlite3_stmt *stmt;
    if (sqlite3_prepare_v2(_db, sql, -1, &stmt, NULL) == SQLITE_OK) {
        while (sqlite3_step(stmt) == SQLITE_ROW) {
            RssArticle *a = [[RssArticle alloc] init];
            const char *cId = (const char *)sqlite3_column_text(stmt, 0);
            if (cId) a.articleId = [NSString stringWithUTF8String:cId];
            const char *cTitle = (const char *)sqlite3_column_text(stmt, 1);
            if (cTitle) a.title = [NSString stringWithUTF8String:cTitle];
            const char *cSummary = (const char *)sqlite3_column_text(stmt, 2);
            if (cSummary) a.summary = [NSString stringWithUTF8String:cSummary];
            const char *cContent = (const char *)sqlite3_column_text(stmt, 3);
            if (cContent) a.content = [NSString stringWithUTF8String:cContent];
            const char *cLink = (const char *)sqlite3_column_text(stmt, 4);
            if (cLink) a.link = [NSString stringWithUTF8String:cLink];
            const char *cPubDate = (const char *)sqlite3_column_text(stmt, 5);
            if (cPubDate) a.pubDate = [NSString stringWithUTF8String:cPubDate];
            a.isRead = NO;
            a.isStarred = sqlite3_column_int(stmt, 8) == 1;
            const char *cFeedUrl = (const char *)sqlite3_column_text(stmt, 7);
            if (cFeedUrl) a.feedUrl = [NSString stringWithUTF8String:cFeedUrl];
            [results addObject:a];
        }
    }
    sqlite3_finalize(stmt);
    return results;
}

// 统计方法与标记已读
- (NSInteger)unreadCountForFeed:(NSString *)feedUrl {
    const char *sql = "SELECT COUNT(*) FROM articles WHERE feed_url = ? AND is_read = 0";
    sqlite3_stmt *stmt;
    NSInteger count = 0;
    if (sqlite3_prepare_v2(_db, sql, -1, &stmt, NULL) == SQLITE_OK) {
        sqlite3_bind_text(stmt, 1, [feedUrl UTF8String], -1, SQLITE_TRANSIENT);
        if (sqlite3_step(stmt) == SQLITE_ROW) count = sqlite3_column_int(stmt, 0);
    }
    sqlite3_finalize(stmt);
    return count;
}

- (NSInteger)totalUnreadCount {
    const char *sql = "SELECT COUNT(*) FROM articles WHERE is_read = 0";
    sqlite3_stmt *stmt;
    NSInteger count = 0;
    if (sqlite3_prepare_v2(_db, sql, -1, &stmt, NULL) == SQLITE_OK) {
        if (sqlite3_step(stmt) == SQLITE_ROW) count = sqlite3_column_int(stmt, 0);
    }
    sqlite3_finalize(stmt);
    return count;
}

- (void)setArticleReadStatus:(NSString *)articleId isRead:(BOOL)isRead {
    const char *sql = "UPDATE articles SET is_read = ? WHERE id = ?";
    sqlite3_stmt *stmt;
    if (sqlite3_prepare_v2(_db, sql, -1, &stmt, NULL) == SQLITE_OK) {
        sqlite3_bind_int(stmt, 1, isRead ? 1 : 0);
        sqlite3_bind_text(stmt, 2, [articleId UTF8String], -1, SQLITE_TRANSIENT);
        sqlite3_step(stmt);
    }
    sqlite3_finalize(stmt);
}

- (NSArray<RssArticle *> *)articlesForFeed:(NSString *)feedUrl {
    NSMutableArray *results = [NSMutableArray array];
    const char *sql = "SELECT id, title, summary, content, link, pub_date, is_read, is_starred FROM articles WHERE feed_url = ? ORDER BY pub_date DESC";
    sqlite3_stmt *stmt;
    if (sqlite3_prepare_v2(_db, sql, -1, &stmt, NULL) == SQLITE_OK) {
        sqlite3_bind_text(stmt, 1, [feedUrl UTF8String], -1, SQLITE_TRANSIENT);
        while (sqlite3_step(stmt) == SQLITE_ROW) {
            RssArticle *a = [[RssArticle alloc] init];

            // 安全读取，防止 NULL 指针导致 stringWithUTF8String 抛出异常崩溃
            const char *cId = (const char *)sqlite3_column_text(stmt, 0);
            if (cId) a.articleId = [NSString stringWithUTF8String:cId];

            const char *cTitle = (const char *)sqlite3_column_text(stmt, 1);
            if (cTitle) a.title = [NSString stringWithUTF8String:cTitle];

            const char *cSummary = (const char *)sqlite3_column_text(stmt, 2);
            if (cSummary) a.summary = [NSString stringWithUTF8String:cSummary];

            const char *cContent = (const char *)sqlite3_column_text(stmt, 3);
            if (cContent) a.content = [NSString stringWithUTF8String:cContent];

            const char *cLink = (const char *)sqlite3_column_text(stmt, 4);
            if (cLink) a.link = [NSString stringWithUTF8String:cLink];

            const char *cPubDate = (const char *)sqlite3_column_text(stmt, 5);
            if (cPubDate) a.pubDate = [NSString stringWithUTF8String:cPubDate];

            a.isRead = sqlite3_column_int(stmt, 6) == 1;
            a.isStarred = sqlite3_column_int(stmt, 7) == 1;

            a.feedUrl = feedUrl; // 记录来源URL，方便后续查名字
            [results addObject:a];
        }
    }
    sqlite3_finalize(stmt);
    return results;
}

- (NSInteger)totalStarredCount {
    const char *sql = "SELECT COUNT(*) FROM articles WHERE is_starred = 1";
    sqlite3_stmt *stmt;
    NSInteger count = 0;
    if (sqlite3_prepare_v2(_db, sql, -1, &stmt, NULL) == SQLITE_OK) {
        if (sqlite3_step(stmt) == SQLITE_ROW) count = sqlite3_column_int(stmt, 0);
    }
    sqlite3_finalize(stmt);
    return count;
}

- (void)toggleStarForArticle:(NSString *)articleId starred:(BOOL)isStarred {
    const char *sql = "UPDATE articles SET is_starred = ? WHERE id = ?";
    sqlite3_stmt *stmt;
    if (sqlite3_prepare_v2(_db, sql, -1, &stmt, NULL) == SQLITE_OK) {
        sqlite3_bind_int(stmt, 1, isStarred ? 1 : 0);
        sqlite3_bind_text(stmt, 2, [articleId UTF8String], -1, SQLITE_TRANSIENT);
        sqlite3_step(stmt);
    }
    sqlite3_finalize(stmt);
}

- (NSArray<RssArticle *> *)allStarredArticles {
    NSMutableArray *results = [NSMutableArray array];
    const char *sql = "SELECT id, title, summary, content, link, pub_date, is_read, feed_url, is_starred FROM articles WHERE is_starred = 1 ORDER BY pub_date DESC";
    sqlite3_stmt *stmt;
    if (sqlite3_prepare_v2(_db, sql, -1, &stmt, NULL) == SQLITE_OK) {
        while (sqlite3_step(stmt) == SQLITE_ROW) {
            RssArticle *a = [[RssArticle alloc] init];
            const char *cId = (const char *)sqlite3_column_text(stmt, 0);
            if (cId) a.articleId = [NSString stringWithUTF8String:cId];
            const char *cTitle = (const char *)sqlite3_column_text(stmt, 1);
            if (cTitle) a.title = [NSString stringWithUTF8String:cTitle];
            const char *cSummary = (const char *)sqlite3_column_text(stmt, 2);
            if (cSummary) a.summary = [NSString stringWithUTF8String:cSummary];
            const char *cContent = (const char *)sqlite3_column_text(stmt, 3);
            if (cContent) a.content = [NSString stringWithUTF8String:cContent];
            const char *cLink = (const char *)sqlite3_column_text(stmt, 4);
            if (cLink) a.link = [NSString stringWithUTF8String:cLink];
            const char *cPubDate = (const char *)sqlite3_column_text(stmt, 5);
            if (cPubDate) a.pubDate = [NSString stringWithUTF8String:cPubDate];
            a.isRead = sqlite3_column_int(stmt, 6) == 1;
            const char *cFeedUrl = (const char *)sqlite3_column_text(stmt, 7);
            if (cFeedUrl) a.feedUrl = [NSString stringWithUTF8String:cFeedUrl];
            a.isStarred = YES; // 肯定是 YES
            [results addObject:a];
        }
    }
    sqlite3_finalize(stmt);
    return results;
}


@end

#pragma mark - RSS Parser (NSXMLParser)

@interface RssFeedParser : NSObject <NSXMLParserDelegate>
@property (nonatomic, strong) RssNode *feedNode;
@property (nonatomic, copy) NSString *feedUrl;
@property (nonatomic, strong) RssArticle *currentArticle;
@property (nonatomic, strong) NSMutableString *currentString;
@property (nonatomic, copy) void (^completion)(void);
@end

@implementation RssFeedParser
- (void)parseUrl:(NSString *)url completion:(void (^)(void))completion {
    self.feedUrl = url;
    self.completion = completion;
    APPINE_LOG(@"[Appine RSS] 🌐 开始抓取: %@", url);

    NSURLSession *session = [NSURLSession sharedSession];
    [[session dataTaskWithURL:[NSURL URLWithString:url] completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error) {
            APPINE_LOG(@"[Appine RSS] ❌ 抓取失败 %@: %@", url, error.localizedDescription);
        } else if (data) {
            APPINE_LOG(@"[Appine RSS] ⬇️ 成功下载 %@, 数据大小: %ld bytes", url, (long)data.length);
            NSXMLParser *parser = [[NSXMLParser alloc] initWithData:data];
            parser.delegate = self;
            BOOL success = [parser parse];
            if (!success) {
                APPINE_LOG(@"[Appine RSS] ⚠️ XML 解析失败 %@: %@", url, parser.parserError);
            } else {
                APPINE_LOG(@"[Appine RSS] ✅ XML 解析完成 %@", url);
            }
        }

        if (self.completion) {
            dispatch_async(dispatch_get_main_queue(), self.completion);
        }
    }] resume];
}

- (void)parser:(NSXMLParser *)parser didStartElement:(NSString *)elementName namespaceURI:(NSString *)namespaceURI qualifiedName:(NSString *)qName attributes:(NSDictionary<NSString *,NSString *> *)attributeDict {
    if ([elementName isEqualToString:@"item"] || [elementName isEqualToString:@"entry"]) {
        self.currentArticle = [[RssArticle alloc] init];
        self.currentArticle.feedUrl = self.feedUrl;
        // 将计算好的 Org 文件路径传给文章
        self.currentArticle.orgFilePath = [self.feedNode orgFilePath];
    }
    // 支持 Atom 协议的 <link href="...">
    else if ([elementName isEqualToString:@"link"]) {
        NSString *href = attributeDict[@"href"];
        if (href && self.currentArticle) {
            self.currentArticle.link = href;
        }
    }
    self.currentString = [NSMutableString string];
}

- (void)parser:(NSXMLParser *)parser foundCharacters:(NSString *)string {
    [self.currentString appendString:string];
}

- (void)parser:(NSXMLParser *)parser didEndElement:(NSString *)elementName namespaceURI:(NSString *)namespaceURI qualifiedName:(NSString *)qName {
    if ([elementName isEqualToString:@"item"] || [elementName isEqualToString:@"entry"]) {
        [[RssDatabase shared] saveArticle:self.currentArticle];
        self.currentArticle = nil;
    } else if (self.currentArticle) {
        NSString *str = [self.currentString stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if ([elementName isEqualToString:@"title"]) self.currentArticle.title = str;
        // 如果 str 有内容才赋值，防止把上面解析到的 href 覆盖掉
        else if ([elementName isEqualToString:@"link"] && str.length > 0) self.currentArticle.link = str;
        // 解析 RSS 的 guid 或 Atom 的 id
        else if ([elementName isEqualToString:@"id"] || [elementName isEqualToString:@"guid"]) self.currentArticle.articleId = str;
        else if ([elementName isEqualToString:@"description"] || [elementName isEqualToString:@"summary"]) self.currentArticle.summary = str;
        else if ([elementName isEqualToString:@"content:encoded"] || [elementName isEqualToString:@"content"]) self.currentArticle.content = str;
        else if ([elementName isEqualToString:@"pubDate"] || [elementName isEqualToString:@"published"]) self.currentArticle.pubDate = str;
    }
}

@end

#pragma mark - Main Backend UI

// 自定义侧边栏的选中背景
@interface AppineSidebarRowView : NSTableRowView
@end
@implementation AppineSidebarRowView
- (void)drawSelectionInRect:(NSRect)dirtyRect {
    // 绘制浅色圆角矩形。因为我们不判断焦点状态，所以失去焦点后背景色依然会保持！
    [[NSColor colorWithCalibratedWhite:0.5 alpha:0.2] setFill];
    NSBezierPath *path = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds, 8, 2) xRadius:6 yRadius:6];
    [path fill];
}
// 强制文字保持深色（防止系统默认在选中时把文字变成白色，导致看不清）
- (NSBackgroundStyle)interiorBackgroundStyle {
    return NSBackgroundStyleNormal;
}
@end
@interface AppineListRowView : NSTableRowView
@end
@implementation AppineListRowView
- (void)drawSelectionInRect:(NSRect)dirtyRect {
    // 同样使用浅灰色半透明背景
    [[NSColor colorWithCalibratedWhite:0.5 alpha:0.2] setFill];
    // 列表区域较宽，左右边距设为 4 即可
    NSBezierPath *path = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds, 4, 2) xRadius:6 yRadius:6];
    [path fill];
}
// 强制文字保持深色（防止系统默认在选中时把文字变成白色，导致看不清）
- (NSBackgroundStyle)interiorBackgroundStyle {
    return NSBackgroundStyleNormal;
}
@end

@interface AppineRssBackend : NSObject <AppineBackend, NSSplitViewDelegate, NSOutlineViewDataSource, NSOutlineViewDelegate, NSTableViewDataSource, NSTableViewDelegate, WKNavigationDelegate>
@property (nonatomic, strong) NSSplitView *splitView;
@property (nonatomic, strong) NSOutlineView *sidebarView;
@property (nonatomic, strong) NSTableView *listView;
@property (nonatomic, strong) WKWebView *webView;

@property (nonatomic, strong) RssNode *rootNode;
@property (nonatomic, strong) NSArray<RssArticle *> *currentArticles;

// 用于动画和并发控制的属性
@property (nonatomic, strong) NSButton *refreshBtn;
@property (nonatomic, strong) dispatch_group_t fetchGroup;

@end

@implementation AppineRssBackend

extern void appine_core_add_web_tab(NSString *urlString);


- (void)dealloc {
}

- (void)cleanup {
  appine_cleanup_webview_plugins(self.webView.configuration);
  [self.webView stopLoading];
  [self.webView loadHTMLString:@"" baseURL:nil];
}

// 根据 url 递归查找订阅源名称
- (NSString *)feedNameForUrl:(NSString *)url node:(RssNode *)node {
    if ([node.url isEqualToString:url]) return node.name;
    for (RssNode *child in node.children) {
        NSString *res = [self feedNameForUrl:url node:child];
        if (res) return res;
    }
    return nil;
}
// 根据 url 递归查找订阅源节点
- (RssNode *)nodeForUrl:(NSString *)url node:(RssNode *)node {
    if ([node.url isEqualToString:url]) return node;
    for (RssNode *child in node.children) {
        RssNode *res = [self nodeForUrl:url node:child];
        if (res) return res;
    }
    return nil;
}


// 智能格式化日期 (2周内显示 days ago，否则 yyyy-MM-dd)
- (NSString *)formatRelativeDate:(NSString *)pubDate {
    if (!pubDate || pubDate.length == 0) return @"";
    NSDataDetector *detector = [NSDataDetector dataDetectorWithTypes:NSTextCheckingTypeDate error:nil];
    NSTextCheckingResult *match = [detector firstMatchInString:pubDate options:0 range:NSMakeRange(0, pubDate.length)];
    NSDate *date = match.date;
    if (!date) return pubDate;

    NSTimeInterval diff = [[NSDate date] timeIntervalSinceDate:date];
    if (diff >= 0 && diff < 14 * 24 * 3600) {
        int days = diff / (24 * 3600);
        if (days == 0) return @"today";
        if (days == 1) return @"1 day ago";
        return [NSString stringWithFormat:@"%d days ago", days];
    } else {
        NSDateFormatter *df = [[NSDateFormatter alloc] init];
        df.dateFormat = @"yyyy-MM-dd";
        return [df stringFromDate:date];
    }
}

- (AppineBackendKind)kind { return AppineBackendKindRss; }

- (instancetype)initWithPath:(NSString *)path {
    self = [super init];
    if (self) {
        // 1. 确定工作路径
        BOOL isDir = NO;
        if ([[NSFileManager defaultManager] fileExistsAtPath:path isDirectory:&isDir]) {
            g_rss_work_path = isDir ? path : [path stringByDeletingLastPathComponent];
        } else {
            // 兜底路径
            g_rss_work_path = [NSHomeDirectory() stringByAppendingPathComponent:@".emacs.d"];
        }

        // 2. 初始化数据库
        [[RssDatabase shared] setupDatabase];

        self.fetchGroup = dispatch_group_create();

        // 3. 解析文件
        [self parseOrgFilesAtPath:path isDirectory:isDir];

        [self setupUI];
        dispatch_async(dispatch_get_main_queue(), ^{
            [self fetchAllFeeds];
        });
        [NSTimer scheduledTimerWithTimeInterval:900 target:self selector:@selector(fetchAllFeeds) userInfo:nil repeats:YES];
    }
    return self;
}

// 解析 elfeed.org
- (void)parseOrgFilesAtPath:(NSString *)path isDirectory:(BOOL)isDir {
    self.rootNode = [[RssNode alloc] init];
    self.rootNode.name = @"Subscriptions";

    NSMutableArray *filesToParse = [NSMutableArray array];
    if (isDir) {
        NSArray *contents = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:path error:nil];
        for (NSString *file in contents) {
            if ([file.pathExtension isEqualToString:@"org"]) {
                [filesToParse addObject:[path stringByAppendingPathComponent:file]];
            }
        }
    } else {
        [filesToParse addObject:path];
    }

    int feedCount = 0;
    for (NSString *filePath in filesToParse) {
        NSError *error;
        NSString *content = [NSString stringWithContentsOfFile:filePath encoding:NSUTF8StringEncoding error:&error];
        if (!content) {
            APPINE_LOG(@"[Appine RSS] ❌ 读取文件失败 %@: %@", filePath, error);
            continue;
        }

        NSArray *lines = [content componentsSeparatedByString:@"\n"];
        NSMutableArray<RssNode *> *stack = [NSMutableArray arrayWithObject:self.rootNode];

        for (NSString *line in lines) {
            if (![line hasPrefix:@"*"]) continue;

            NSInteger depth = 0;
            while (depth < (NSInteger)line.length && [line characterAtIndex:depth] == '*') depth++;

            NSString *text = [[line substringFromIndex:depth] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            NSRange tagRange = [text rangeOfString:@" :"];
            if (tagRange.location != NSNotFound) {
                text = [[text substringToIndex:tagRange.location] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            }

            RssNode *node = [[RssNode alloc] init];
            BOOL isFeed = NO;

            if ([text hasPrefix:@"[["] && [text containsString:@"]["] && [text hasSuffix:@"]]"]) {
                NSRange midRange = [text rangeOfString:@"]["];
                node.url = [text substringWithRange:NSMakeRange(2, midRange.location - 2)];
                node.name = [text substringWithRange:NSMakeRange(NSMaxRange(midRange), text.length - NSMaxRange(midRange) - 2)];
                isFeed = YES;
            } else if ([text hasPrefix:@"http"]) {
                node.url = text;
                // 如果只有 URL，提取域名作为标题，防止标题过长
                NSURL *url = [NSURL URLWithString:text];
                node.name = url.host ?: [[text componentsSeparatedByString:@"/"] lastObject];
                isFeed = YES;
            } else {
                node.name = text;
            }

            // 【容错】如果是 Feed 但没有解析出 URL，跳过它
            if (isFeed && node.url.length == 0) {
                APPINE_LOG(@"[Appine RSS] ⚠️ 发现无效的订阅节点 (缺少URL)，已忽略: %@", line);
                continue;
            }

            if (isFeed) feedCount++;

            while ((NSInteger)stack.count > depth) [stack removeLastObject];
            RssNode *parent = stack.lastObject;
            [parent.children addObject:node];
            node.parent = parent;
            [stack addObject:node];
        }
    }

    RssNode *unreadNode = [[RssNode alloc] init];
    unreadNode.name = @"Unread";
    unreadNode.isSpecialUnread = YES;
    [self.rootNode.children insertObject:unreadNode atIndex:0];

    RssNode *starredNode = [[RssNode alloc] init];
    starredNode.name = @"Starred";
    starredNode.isSpecialStarred = YES;
    [self.rootNode.children insertObject:starredNode atIndex:1];

    APPINE_LOG(@"[Appine RSS] 🌳 目录树解析完成，共找到 %d 个订阅源", feedCount);
}

- (void)fetchAllFeeds {
    [self startSpinningAnimation]; // 开始旋转！

    [self fetchNode:self.rootNode];

    // 当 fetchGroup 里的所有任务都离开 (leave) 时，触发这个回调
    dispatch_group_notify(self.fetchGroup, dispatch_get_main_queue(), ^{
        [self stopSpinningAnimation]; // 停止旋转！
        [self.sidebarView reloadData]; // 顺便刷新一下侧边栏的未读角标
    });
}

- (void)fetchNode:(RssNode *)node {
    if (node.url) {
        dispatch_group_enter(self.fetchGroup); // 进入一个异步任务

        RssFeedParser *parser = [[RssFeedParser alloc] init];
        parser.feedNode = node;
        [parser parseUrl:node.url completion:^{
            if ([self.sidebarView itemAtRow:self.sidebarView.selectedRow] == node) {
                [self loadArticlesForNode:node];
            }
            dispatch_group_leave(self.fetchGroup); // 异步任务完成，离开
        }];
    }
    for (RssNode *child in node.children) {
        [self fetchNode:child];
    }
}


- (void)setupUI {
    self.splitView = [[NSSplitView alloc] initWithFrame:NSMakeRect(0, 0, 1000, 600)];
    self.splitView.vertical = YES;
    self.splitView.dividerStyle = NSSplitViewDividerStyleThin;
    self.splitView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    self.splitView.delegate = self;

    // --- 1. 侧边栏及顶部 Header ---
    // 创建左侧总容器
    NSView *leftPane = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 200, 600)];
    leftPane.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

    // 1.1 创建顶部 Header View (高度 44)
    NSView *headerView = [[NSView alloc] initWithFrame:NSMakeRect(0, 600 - 44, 200, 44)];
    headerView.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin; // 紧贴顶部

    // RSS Logo (使用 Base64 直接解码，无需外部文件)
    NSString *rssBase64 = @"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";
    NSData *rssData = [[NSData alloc] initWithBase64EncodedString:rssBase64 options:0];
    NSImage *rssImage = [[NSImage alloc] initWithData:rssData];

    NSImageView *logoView = [[NSImageView alloc] initWithFrame:NSMakeRect(10, 10, 24, 24)];
    logoView.image = rssImage;
    logoView.imageScaling = NSImageScaleProportionallyUpOrDown;
    [headerView addSubview:logoView];

    // 标题文本
    NSTextField *titleLabel = [NSTextField labelWithString:@"Appine RSS"];
    titleLabel.font = [NSFont boldSystemFontOfSize:15];
    titleLabel.frame = NSMakeRect(42, 13, 100, 20);
    [headerView addSubview:titleLabel];

    // 刷新按钮 (使用系统自带的刷新图标，完美支持深色/浅色模式)
    self.refreshBtn = [[NSButton alloc] initWithFrame:NSMakeRect(200 - 34, 10, 24, 24)];
    self.refreshBtn.autoresizingMask = NSViewMinXMargin;
    self.refreshBtn.bezelStyle = NSBezelStyleTexturedRounded;
    self.refreshBtn.image = [NSImage imageNamed:NSImageNameRefreshTemplate];
    self.refreshBtn.target = self;
    self.refreshBtn.action = @selector(fetchAllFeeds);
    self.refreshBtn.bordered = NO;
    self.refreshBtn.toolTip = @"Refresh Feeds";

    // 开启图层支持，并将旋转中心点设为按钮正中心
    self.refreshBtn.wantsLayer = YES;

    [headerView addSubview:self.refreshBtn];

    // 底部加一条浅色的分割线
    NSView *border = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 200, 1)];
    border.autoresizingMask = NSViewWidthSizable;
    border.wantsLayer = YES;
    border.layer.backgroundColor = [NSColor gridColor].CGColor;
    [headerView addSubview:border];

    [leftPane addSubview:headerView];

    // 1.2 创建 Sidebar 的 ScrollView (高度 600 - 44 = 556)
    NSScrollView *sidebarScroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 200, 556)];
    sidebarScroll.hasVerticalScroller = YES;
    sidebarScroll.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

    self.sidebarView = [[NSOutlineView alloc] initWithFrame:sidebarScroll.bounds];
    NSTableColumn *col1 = [[NSTableColumn alloc] initWithIdentifier:@"col1"];
    col1.resizingMask = NSTableColumnAutoresizingMask;
    col1.width = 200;
    [self.sidebarView addTableColumn:col1];
    self.sidebarView.headerView = nil;
    self.sidebarView.dataSource = self;
    self.sidebarView.delegate = self;
    self.sidebarView.rowHeight = 28;
    self.sidebarView.columnAutoresizingStyle = NSTableViewUniformColumnAutoresizingStyle;
    if (@available(macOS 11.0, *)) {
        self.sidebarView.style = NSTableViewStyleSourceList;
    }
    sidebarScroll.documentView = self.sidebarView;

    [leftPane addSubview:sidebarScroll];

    // --- 2. 文章列表 ---
    NSScrollView *listScroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 300, 600)];
    listScroll.hasVerticalScroller = YES;
    listScroll.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

    self.listView = [[NSTableView alloc] initWithFrame:listScroll.bounds];
    NSTableColumn *col2 = [[NSTableColumn alloc] initWithIdentifier:@"col2"];
    col2.resizingMask = NSTableColumnAutoresizingMask;
    col2.width = 300; // 🎯 修复1：显式设置初始列宽
    [self.listView addTableColumn:col2];
    // ... 保持原有 listView 设置 ...
    self.listView.headerView = nil;
    self.listView.dataSource = self;
    self.listView.delegate = self;
    self.listView.rowHeight = 85;
    self.listView.columnAutoresizingStyle = NSTableViewUniformColumnAutoresizingStyle;
    if (@available(macOS 11.0, *)) {
        self.listView.style = NSTableViewStyleInset;
    }
    listScroll.documentView = self.listView;

    // --- 3. 阅读区 ---
    WKWebViewConfiguration *config = [[WKWebViewConfiguration alloc] init];
    // 引入插件
    appine_setup_webview_plugins(config);
    self.webView = [[WKWebView alloc] initWithFrame:NSMakeRect(0, 0, 500, 600) configuration:config];
    self.webView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    self.webView.navigationDelegate = self;

    // 注入类似 Typora / GitHub Markdown 的干净阅读样式
    // NSString *css = @"body { font-family: -apple-system; padding: 20px 40px; max-width: 800px; margin: 0 auto; line-height: 1.6; font-size: 16px; color: #333; } img { max-width: 100%; height: auto; border-radius: 8px; } a { color: #0066cc; text-decoration: none; }";
 NSString *css =
        @":root { color-scheme: light dark; } " // WebView 原生支持深色模式，自动接管基础背景和文字颜色
        @"body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Helvetica, Arial, sans-serif; padding: 20px 40px; max-width: 800px; margin: 0 auto; line-height: 1.6; font-size: 16px; word-wrap: break-word; } "
        @"img { max-width: 100%; height: auto; border-radius: 8px; } "
        @"a { color: #0066cc; text-decoration: none; } "
        @"a:hover { text-decoration: underline; } "
        @"blockquote { padding: 0 1em; color: #6a737d; border-left: 0.25em solid #dfe2e5; margin: 0 0 16px 0; background: transparent; } "
        @"code { padding: 0.2em 0.4em; margin: 0; font-size: 85%; background-color: rgba(27,31,35,0.05); border-radius: 3px; font-family: ui-monospace, SFMono-Regular, Consolas, 'Liberation Mono', Menlo, monospace; } "
        @"pre { padding: 16px; overflow: auto; font-size: 85%; line-height: 1.45; background-color: #f6f8fa; border-radius: 6px; } "
        @"pre code { padding: 0; margin: 0; font-size: 100%; word-break: normal; white-space: pre; background: transparent; border: 0; } "
        @"hr { height: 0.25em; padding: 0; margin: 24px 0; background-color: #e1e4e8; border: 0; } "
        @"table { border-collapse: collapse; width: 100%; margin-bottom: 16px; } "
        @"table th, table td { padding: 6px 13px; border: 1px solid #dfe2e5; } "
        @"table tr:nth-child(2n) { background-color: #f6f8fa; } "
        // 提取文章顶部 Header 的样式
        @".appine-header { display: flex; justify-content: space-between; align-items: center; color: gray; font-size: 13px; border-bottom: 1px solid #eee; padding-bottom: 10px; margin-bottom: 15px; } "
        @".appine-header a { color: #0066cc; margin-right: 15px; } "
        @".appine-header a:last-child { margin-right: 0; } "
        // 深色模式下的颜色覆盖 (Dark Mode 适配)
        @"@media (prefers-color-scheme: dark) { "
        @"  a, .appine-header a { color: #58a6ff; } "
        @"  blockquote { color: #8b949e; border-left-color: #30363d; } "
        @"  code { background-color: rgba(240,246,252,0.15); } "
        @"  pre { background-color: #161b22; } "
        @"  hr { background-color: #30363d; } "
        @"  table th, table td { border-color: #30363d; } "
        @"  table tr:nth-child(2n) { background-color: #161b22; } "
        @"  .appine-header { border-bottom-color: #30363d; color: #8b949e; } "
        @"}";

    WKUserScript *script = [[WKUserScript alloc] initWithSource:[NSString stringWithFormat:@"var style = document.createElement('style'); style.innerHTML = `%@`; document.head.appendChild(style);", css] injectionTime:WKUserScriptInjectionTimeAtDocumentEnd forMainFrameOnly:YES];

    [config.userContentController addUserScript:script];

    [self.splitView addSubview:leftPane];
    [self.splitView addSubview:listScroll];
    [self.splitView addSubview:self.webView];

    [self.splitView adjustSubviews];
    [self.splitView setPosition:200 ofDividerAtIndex:0];
    [self.splitView setPosition:500 ofDividerAtIndex:1];
    [self.sidebarView expandItem:nil expandChildren:YES];
}

- (void)startSpinningAnimation {
    // 如果已经在转了，就不重复添加动画
    if ([self.refreshBtn.layer animationForKey:@"spin"]) return;

    // 在动画开始前，强制将锚点移到中心，并同步修正 position
    CGRect frame = self.refreshBtn.frame;
    self.refreshBtn.layer.anchorPoint = CGPointMake(0.5, 0.5);
    self.refreshBtn.layer.position = CGPointMake(NSMidX(frame), NSMidY(frame));

    // 使用 transform.rotation.z 进行 Z 轴旋转
    CABasicAnimation *spin = [CABasicAnimation animationWithKeyPath:@"transform.rotation.z"];
    spin.duration = 1.0;         // 转一圈需要 1 秒
    spin.byValue = @(-2 * M_PI); // 顺时针相对旋转 360 度 (使用 byValue 更平滑)
    spin.repeatCount = HUGE_VALF; // 无限循环

    [self.refreshBtn.layer addAnimation:spin forKey:@"spin"];
}

- (void)stopSpinningAnimation {
    // 移除旋转动画
    [self.refreshBtn.layer removeAnimationForKey:@"spin"];

    // 动画结束后，将锚点恢复为 AppKit 默认的 (0,0)，防止后续调整窗口大小时布局错乱
    CGRect frame = self.refreshBtn.frame;
    self.refreshBtn.layer.anchorPoint = CGPointMake(0, 0);
    self.refreshBtn.layer.position = CGPointMake(NSMinX(frame), NSMinY(frame));
}


#pragma mark - NSSplitViewDelegate (防止白屏和列消失)
- (CGFloat)splitView:(NSSplitView *)splitView constrainMinCoordinate:(CGFloat)proposedMinimumPosition ofSubviewAt:(NSInteger)dividerIndex {
    if (dividerIndex == 0) return 150; // 侧边栏最窄 150
    if (dividerIndex == 1) return 150 + 250; // 列表最窄 250
    return proposedMinimumPosition;
}

- (CGFloat)splitView:(NSSplitView *)splitView constrainMaxCoordinate:(CGFloat)proposedMaximumPosition ofSubviewAt:(NSInteger)dividerIndex {
    if (dividerIndex == 0) return 300; // 侧边栏最宽 300
    if (dividerIndex == 1) return splitView.bounds.size.width - 300; // 给 WebView 强制留出至少 300 的空间
    return proposedMaximumPosition;
}

- (BOOL)splitView:(NSSplitView *)splitView canCollapseSubview:(NSView *)subview {
    return NO; // 严禁任何一列被折叠隐藏
}

- (NSView *)view { return self.splitView; }
- (NSString *)title { return @"AppineRssReader"; }

#pragma mark - NSOutlineView (Sidebar)

// Sidebar 使用我们上面自定义的 RowView
- (NSTableRowView *)outlineView:(NSOutlineView *)outlineView rowViewForItem:(id)item {
    return [[AppineSidebarRowView alloc] init];
}

- (NSInteger)outlineView:(NSOutlineView *)outlineView numberOfChildrenOfItem:(id)item {
    RssNode *node = item ?: self.rootNode;
    return node.children.count;
}
- (BOOL)outlineView:(NSOutlineView *)outlineView isItemExpandable:(id)item {
    return ((RssNode *)item).children.count > 0;
}
- (id)outlineView:(NSOutlineView *)outlineView child:(NSInteger)index ofItem:(id)item {
    RssNode *node = item ?: self.rootNode;
    return node.children[index];
}
- (NSView *)outlineView:(NSOutlineView *)outlineView viewForTableColumn:(NSTableColumn *)tableColumn item:(id)item {
    // 使用 NSTableCellView 组合文本和角标
    NSTableCellView *cell = [outlineView makeViewWithIdentifier:@"SidebarCell" owner:self];
    if (!cell) {
        cell = [[NSTableCellView alloc] initWithFrame:NSMakeRect(0, 0, 200, 28)];
        cell.identifier = @"SidebarCell";

        NSTextField *textField = [NSTextField labelWithString:@""];
        textField.identifier = @"Text";
        // 行高28，文本框高18，Y设为5刚好上下居中 ((28-18)/2 = 5)
        textField.frame = NSMakeRect(0, 5, 150, 18);
        textField.autoresizingMask = NSViewWidthSizable;
        textField.lineBreakMode = NSLineBreakByTruncatingTail;
        [cell addSubview:textField];

        NSTextField *badge = [NSTextField labelWithString:@""];
        badge.identifier = @"Badge";
        // 行高28，角标高16，Y设为6刚好上下居中 ((28-16)/2 = 6)
        badge.frame = NSMakeRect(160, 6, 30, 16);
        badge.autoresizingMask = NSViewMinXMargin;
        // badge.backgroundColor = [NSColor controlAccentColor]; // 保持深色背景
        // badge.textColor = [NSColor whiteColor];
        badge.drawsBackground = YES;
        badge.alignment = NSTextAlignmentCenter;
        badge.wantsLayer = YES;
        badge.layer.cornerRadius = 8; // 圆角必须是高度(16)的一半
        badge.layer.masksToBounds = YES;
        badge.font = [NSFont boldSystemFontOfSize:11];
        [cell addSubview:badge];
    }

    RssNode *node = item;
    NSTextField *textField = nil;
    NSTextField *badge = nil;
    for (NSView *v in cell.subviews) {
        if ([v.identifier isEqualToString:@"Text"]) textField = (NSTextField *)v;
        if ([v.identifier isEqualToString:@"Badge"]) badge = (NSTextField *)v;
    }

    textField.stringValue = node.name ?: @"Unknown";
    textField.font = node.url ? [NSFont systemFontOfSize:13] : [NSFont boldSystemFontOfSize:13];

    NSInteger unread = [node unreadCount];
    if (unread > 0) {
        badge.stringValue = [NSString stringWithFormat:@"%ld", (long)unread];
        badge.hidden = NO;

        // 根据节点类型应用不同的现代风格配色（动态适配深色模式）
        NSColor *accentBg = [NSColor colorWithName:nil dynamicProvider:^NSColor *(NSAppearance *app) {
            return [[NSColor controlAccentColor] colorWithAlphaComponent:[app.name containsString:@"Dark"] ? 0.35 : 0.15];
        }];
        NSColor *grayBg = [NSColor colorWithName:nil dynamicProvider:^NSColor *(NSAppearance *app) {
            return [app.name containsString:@"Dark"] ? [[NSColor whiteColor] colorWithAlphaComponent:0.2] : [[NSColor grayColor] colorWithAlphaComponent:0.15];
        }];

        if (node.isSpecialStarred) {
            badge.backgroundColor = grayBg;
            // 将 secondaryLabelColor 改为 labelColor，深色模式下会自动变成纯白色，对比度极高
            badge.textColor = [NSColor labelColor];
        } else {
            badge.backgroundColor = accentBg;
            badge.textColor = [NSColor labelColor];
        }
    } else {
        badge.hidden = YES;
    }
    return cell;
}

- (void)outlineViewSelectionDidChange:(NSNotification *)notification {
    RssNode *node = [self.sidebarView itemAtRow:self.sidebarView.selectedRow];
    // 支持点击 Unread 节点
    if (node.isSpecialUnread) {
        NSArray *articles = [[RssDatabase shared] allUnreadArticles];
        // 按真实时间降序排序
        self.currentArticles = [articles sortedArrayUsingComparator:^NSComparisonResult(RssArticle *a, RssArticle *b) {
            return [b.parsedDate compare:a.parsedDate];
        }];
        [self.listView reloadData];
    } else if (node.isSpecialStarred) {
        NSArray *articles = [[RssDatabase shared] allStarredArticles];
        // 按真实时间降序排序
        self.currentArticles = [articles sortedArrayUsingComparator:^NSComparisonResult(RssArticle *a, RssArticle *b) {
            return [b.parsedDate compare:a.parsedDate];
        }];
        [self.listView reloadData];
    } else if (node && node.url) {
        [self loadArticlesForNode:node];
    } else {
        self.currentArticles = @[];
        [self.listView reloadData];
    }
}

- (void)loadArticlesForNode:(RssNode *)node {
    NSArray *articles = [[RssDatabase shared] articlesForFeed:node.url];
    // 按真实时间降序排序
    self.currentArticles = [articles sortedArrayUsingComparator:^NSComparisonResult(RssArticle *a, RssArticle *b) {
        return [b.parsedDate compare:a.parsedDate];
    }];
    [self.listView reloadData];
}


#pragma mark - NSTableView (Article List)

// ListView 使用自定义的浅色选中背景
- (NSTableRowView *)tableView:(NSTableView *)tableView rowViewForRow:(NSInteger)row {
    return [[AppineListRowView alloc] init];
}
- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    return self.currentArticles.count;
}

- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row {
    // 使用 NSTableCellView 组合标题摘要、底部信息和角标
    NSTableCellView *cell = [tableView makeViewWithIdentifier:@"ListCell" owner:self];
    if (!cell) {
        cell = [[NSTableCellView alloc] initWithFrame:NSMakeRect(0, 0, 300, 85)];
        cell.identifier = @"ListCell";

        NSTextField *text = [NSTextField labelWithString:@""];
        text.identifier = @"Text";
        text.frame = NSMakeRect(10, 25, 280, 55);
        text.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        text.cell.wraps = YES;
        text.cell.truncatesLastVisibleLine = YES;
        text.maximumNumberOfLines = 3;
        [cell addSubview:text];

        NSTextField *footer = [NSTextField labelWithString:@""];
        footer.identifier = @"Footer";
        footer.frame = NSMakeRect(10, 5, 230, 15);
        footer.autoresizingMask = NSViewWidthSizable | NSViewMaxYMargin;
        [cell addSubview:footer];

        NSTextField *badge = [NSTextField labelWithString:@"unread"];
        badge.identifier = @"Badge";
        badge.frame = NSMakeRect(240, 5, 50, 15);
        badge.autoresizingMask = NSViewMinXMargin | NSViewMaxYMargin;
        // badge.backgroundColor = [NSColor controlAccentColor]; // 深色背景
        // badge.textColor = [NSColor whiteColor];
        badge.drawsBackground = YES;
        badge.alignment = NSTextAlignmentCenter;
        badge.font = [NSFont boldSystemFontOfSize:10];
        badge.wantsLayer = YES;
        badge.layer.cornerRadius = 4;
        badge.layer.masksToBounds = YES;
        [cell addSubview:badge];
    }

    RssArticle *article = self.currentArticles[row];
    NSTextField *text = nil;
    NSTextField *footer = nil;
    NSTextField *badge = nil;
    for (NSView *v in cell.subviews) {
        if ([v.identifier isEqualToString:@"Text"]) text = (NSTextField *)v;
        if ([v.identifier isEqualToString:@"Footer"]) footer = (NSTextField *)v;
        if ([v.identifier isEqualToString:@"Badge"]) badge = (NSTextField *)v;
    }

    NSMutableAttributedString *attrStr = [[NSMutableAttributedString alloc] init];
    NSMutableAttributedString *titleAttr = [[NSMutableAttributedString alloc] init];
    if (article.isStarred) {
        [titleAttr appendAttributedString:[[NSAttributedString alloc] initWithString:@"★ " attributes:@{NSFontAttributeName: [NSFont boldSystemFontOfSize:14], NSForegroundColorAttributeName: [NSColor systemYellowColor]}]];
    }
    [titleAttr appendAttributedString:[[NSAttributedString alloc] initWithString:[NSString stringWithFormat:@"%@\n", article.title ?: @"No Title"] attributes:@{NSFontAttributeName: [NSFont boldSystemFontOfSize:14], NSForegroundColorAttributeName: [NSColor labelColor]}]];

    [attrStr appendAttributedString:titleAttr];
    NSString *cleanSummary = [article.summary stringByReplacingOccurrencesOfString:@"<[^>]+>" withString:@"" options:NSRegularExpressionSearch range:NSMakeRange(0, article.summary.length)];
    if (cleanSummary.length > 100) cleanSummary = [[cleanSummary substringToIndex:100] stringByAppendingString:@"..."];
    NSAttributedString *summary = [[NSAttributedString alloc] initWithString:cleanSummary ?: @"" attributes:@{NSFontAttributeName: [NSFont systemFontOfSize:12], NSForegroundColorAttributeName: [NSColor secondaryLabelColor]}];
    [attrStr appendAttributedString:summary];
    text.attributedStringValue = attrStr;

    // 底部来源和日期信息
    NSString *feedName = [self feedNameForUrl:article.feedUrl node:self.rootNode] ?: @"Unknown";
    NSString *dateStr = [self formatRelativeDate:article.pubDate];
    NSMutableAttributedString *footerAttr = [[NSMutableAttributedString alloc] init];
    [footerAttr appendAttributedString:[[NSAttributedString alloc] initWithString:[NSString stringWithFormat:@"%@ • ", feedName] attributes:@{NSFontAttributeName: [NSFont boldSystemFontOfSize:11], NSForegroundColorAttributeName: [NSColor secondaryLabelColor]}]];
    [footerAttr appendAttributedString:[[NSAttributedString alloc] initWithString:dateStr attributes:@{NSFontAttributeName: [NSFont systemFontOfSize:11], NSForegroundColorAttributeName: [NSColor secondaryLabelColor]}]];
    footer.attributedStringValue = footerAttr;

    badge.hidden = article.isRead;
    if (!article.isRead) {
        // 使用温和的未读样式
        badge.backgroundColor = [[NSColor controlAccentColor] colorWithAlphaComponent:0.15];
        badge.textColor = [NSColor labelColor];
    }
    // 未读角标控制
    badge.hidden = article.isRead;
    if (!article.isRead) {
        // 使用温和的未读样式（动态适配深色模式）
        badge.backgroundColor = [NSColor colorWithName:nil dynamicProvider:^NSColor *(NSAppearance *app) {
            return [[NSColor controlAccentColor] colorWithAlphaComponent:[app.name containsString:@"Dark"] ? 0.35 : 0.15];
        }];
        badge.textColor = [NSColor labelColor];
    }

    return cell;
}

// 专门用于 WebView 的日期格式化 (本地时区，精确到秒)
- (NSString *)formatWebViewDate:(NSString *)pubDate {
    if (!pubDate || pubDate.length == 0) return @"";
    NSDataDetector *detector = [NSDataDetector dataDetectorWithTypes:NSTextCheckingTypeDate error:nil];
    NSTextCheckingResult *match = [detector firstMatchInString:pubDate options:0 range:NSMakeRange(0, pubDate.length)];
    NSDate *date = match.date;
    if (!date) return pubDate;

    NSTimeInterval diff = [[NSDate date] timeIntervalSinceDate:date];
    if (diff >= 0 && diff < 14 * 24 * 3600) {
        int days = diff / (24 * 3600);
        if (days == 0) return @"today";
        if (days == 1) return @"1 day ago";
        return [NSString stringWithFormat:@"%d days ago", days];
    } else {
        NSDateFormatter *df = [[NSDateFormatter alloc] init];
        df.dateFormat = @"yyyy-MM-dd HH:mm:ss"; // 精确到秒
        df.timeZone = [NSTimeZone localTimeZone]; // 转换为本地时区
        return [df stringFromDate:date];
    }
}

// 辅助方法：局部刷新侧边栏可见的角标，绝对避免 reloadData 导致选中状态丢失
- (void)refreshSidebarBadges {
    for (NSInteger i = 0; i < self.sidebarView.numberOfRows; i++) {
        NSTableCellView *cell = [self.sidebarView viewAtColumn:0 row:i makeIfNecessary:NO];
        if (cell) {
            RssNode *node = [self.sidebarView itemAtRow:i];
            for (NSView *v in cell.subviews) {
                if ([v.identifier isEqualToString:@"Badge"]) {
                    NSTextField *badge = (NSTextField *)v;
                    NSInteger unread = [node unreadCount];
                    if (unread > 0) {
                        badge.stringValue = [NSString stringWithFormat:@"%ld", (long)unread];
                        badge.hidden = NO;
                        // 同步更新颜色逻辑（动态适配深色模式）
                        NSColor *accentBg = [NSColor colorWithName:nil dynamicProvider:^NSColor *(NSAppearance *app) {
                            return [[NSColor controlAccentColor] colorWithAlphaComponent:[app.name containsString:@"Dark"] ? 0.35 : 0.15];
                        }];
                        NSColor *grayBg = [NSColor colorWithName:nil dynamicProvider:^NSColor *(NSAppearance *app) {
                            return [[NSColor grayColor] colorWithAlphaComponent:[app.name containsString:@"Dark"] ? 0.35 : 0.15];
                        }];

                        if (node.isSpecialStarred) {
                            badge.backgroundColor = grayBg;
                            badge.textColor = [NSColor secondaryLabelColor];
                        } else {
                            badge.backgroundColor = accentBg;
                            badge.textColor = [NSColor labelColor];
                        }
                    } else {
                        badge.hidden = YES;
                    }
                    break;
                }
            }
        }
    }
}

- (void)tableViewSelectionDidChange:(NSNotification *)notification {
    NSInteger row = self.listView.selectedRow;
    if (row >= 0 && row < (NSInteger)self.currentArticles.count) {
        RssArticle *article = self.currentArticles[row];
        NSString *htmlContent = article.content.length > 0 ? article.content : article.summary;

        // 构建带左右布局的 Header，并注入自定义协议的 appine:// 链接
        NSString *dateStr = [self formatWebViewDate:article.pubDate];
        // 获取订阅源名称
        NSString *feedName = [self feedNameForUrl:article.feedUrl node:self.rootNode] ?: @"Unknown";
        // 将来源和日期拼接在一起
        NSString *displayInfo = [NSString stringWithFormat:@"%@ • %@", feedName, dateStr];

        NSString *encodedUrl = [article.link stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]] ?: @"";

        NSString *starIcon = article.isStarred ? @"★" : @"☆";
        NSString *starColor = article.isStarred ? @"#ffcc00" : @"gray";
        NSString *starText = article.isStarred ? @"Starred" : @"Star";
        NSString *encodedId = [article.articleId stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]] ?: @"";

        // info, date, star, read status, read original, open in browser
        NSString *headerHtml = [NSString stringWithFormat:@"<div class='appine-header'><span>%@</span><div><a href='appine://toggle-star?id=%@' style='color: %@; font-size: 14px; text-decoration: none;'>%@ %@</a><a href='appine://mark-unread?id=%@' style='text-decoration: none;'>Mark Unread</a><a href='appine://read-original?url=%@' style='text-decoration: none;'>Read Original</a><a href='appine://open-browser?url=%@' style='text-decoration: none;'>Open in Browser</a></div></div>", displayInfo, encodedId, starColor, starIcon, starText, encodedId, encodedUrl, encodedUrl];
        // 增加 MathJax 配置和 CDN 脚本
        // 注意：Objective-C 字符串中的反斜杠需要转义，所以 \\\\( 最终在 HTML 里会变成 \\(
        NSString *mathJaxScript =
            @"<script>"
            @"MathJax = {"
            @"  tex: {"
            @"    inlineMath: [['$','$'], ['\\\\(','\\\\)']],"
            @"    displayMath: [['$$','$$'], ['\\\\[','\\\\]']]"
            @"  }"
            @"};"
            @"</script>"
            @"<script id=\"MathJax-script\" async src=\"https://cdn.jsdelivr.net/npm/mathjax@3/es5/tex-mml-chtml.js\"></script>";

        // 将 mathJaxScript 拼接到 <head> 中, 在 <head> 中增加 <title>%@</title>，并多传一次 article.title
        NSString *fullHtml = [NSString stringWithFormat:@"<html><head><meta name='viewport' content='width=device-width, initial-scale=1'><title>%@</title>%@</head><body><h1>%@</h1>%@%@</body></html>", article.title, mathJaxScript, article.title, headerHtml, htmlContent];

        // 将 baseURL 设为文章的真实链接，而不是 nil
        NSURL *baseURL = article.link ? [NSURL URLWithString:article.link] : nil;
        [self.webView loadHTMLString:fullHtml baseURL:baseURL];

        // 点击后标记已读，更新数据库并刷新 UI
        if (!article.isRead) {
            article.isRead = YES;
            // 更新数据库
            [[RssDatabase shared] setArticleReadStatus:article.articleId isRead:YES];
            // 同步已读状态到 Org 文件
            [self updateOrgFileForArticle:article];
            // 局部刷新当前行隐藏 unread 标签
            [self.listView reloadDataForRowIndexes:[NSIndexSet indexSetWithIndex:row] columnIndexes:[NSIndexSet indexSetWithIndex:0]];

            // 调用辅助方法刷新侧边栏
            [self refreshSidebarBadges];
        }
    }
}

#pragma mark - WKNavigationDelegate

// 拦截 WebView 中的链接点击
- (void)webView:(WKWebView *)webView decidePolicyForNavigationAction:(WKNavigationAction *)navigationAction decisionHandler:(void (^)(WKNavigationActionPolicy))decisionHandler {
    NSURL *url = navigationAction.request.URL;

    // 1. 拦截我们自定义的 appine:// 协议
    if ([url.scheme isEqualToString:@"appine"]) {
        NSString *host = url.host;
        NSURLComponents *components = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
        NSString *targetUrlStr = nil;
        NSString *targetIdStr = nil;
        for (NSURLQueryItem *item in components.queryItems) {
            if ([item.name isEqualToString:@"url"]) targetUrlStr = item.value;
            if ([item.name isEqualToString:@"id"]) targetIdStr = item.value;
        }

        if ([host isEqualToString:@"toggle-star"] && targetIdStr) {
            // 找到对应的文章
            NSInteger rowIndex = -1;
            for (NSInteger i = 0; i < (NSInteger)self.currentArticles.count; i++) {
                if ([self.currentArticles[i].articleId isEqualToString:targetIdStr]) {
                    rowIndex = i;
                    break;
                }
            }
            if (rowIndex >= 0) {
                RssArticle *article = self.currentArticles[rowIndex];
                article.isStarred = !article.isStarred; // 切换状态

                // 1. 更新数据库
                [[RssDatabase shared] toggleStarForArticle:article.articleId starred:article.isStarred];
                // 2. 更新 Org 文件
                [self updateOrgFileForArticle:article];
                // 3. 局部刷新第二列 (显示/隐藏标题前的星星)
                [self.listView reloadDataForRowIndexes:[NSIndexSet indexSetWithIndex:rowIndex] columnIndexes:[NSIndexSet indexSetWithIndex:0]];
                // 4. 局部刷新第一列 (更新 Starred 节点的数量角标)
                [self.sidebarView reloadDataForRowIndexes:[NSIndexSet indexSetWithIndex:1] columnIndexes:[NSIndexSet indexSetWithIndex:0]];

                // 5. 使用 JS 动态更新 WebView 里的按钮，无需重新加载整个网页！
                NSString *newIcon = article.isStarred ? @"★" : @"☆";
                NSString *newColor = article.isStarred ? @"#ffcc00" : @"gray";
                NSString *newText = article.isStarred ? @"Starred" : @"Star";
                NSString *js = [NSString stringWithFormat:@"var a = document.querySelector('a[href*=\"toggle-star\"]'); if(a) { a.style.color = '%@'; a.innerHTML = '%@ %@'; }", newColor, newIcon, newText];
                [self.webView evaluateJavaScript:js completionHandler:nil];
            }
            decisionHandler(WKNavigationActionPolicyCancel);
            return;
        }
        // 处理 Mark Unread 点击
        if ([host isEqualToString:@"mark-unread"] && targetIdStr) {
            NSInteger rowIndex = -1;
            for (NSInteger i = 0; i < (NSInteger)self.currentArticles.count; i++) {
                if ([self.currentArticles[i].articleId isEqualToString:targetIdStr]) {
                    rowIndex = i;
                    break;
                }
            }
            if (rowIndex >= 0) {
                RssArticle *article = self.currentArticles[rowIndex];
                if (article.isRead) {
                    article.isRead = NO; // 标记为未读

                    // 1. 更新数据库
                    [[RssDatabase shared] setArticleReadStatus:article.articleId isRead:NO];
                    // 2. 同步状态到 Org 文件
                    [self updateOrgFileForArticle:article];
                    // 3. 局部刷新第二列 (重新显示 unread 标签)
                    [self.listView reloadDataForRowIndexes:[NSIndexSet indexSetWithIndex:rowIndex] columnIndexes:[NSIndexSet indexSetWithIndex:0]];
                    // 4. 局部刷新第一列 (更新侧边栏未读数)
                    [self refreshSidebarBadges];

                    // 5. 使用 JS 动态将按钮置灰，提供视觉反馈
                    NSString *js = @"var a = document.querySelector('a[href*=\"mark-unread\"]'); if(a) { a.innerHTML = 'Marked Unread'; a.style.color = 'gray'; a.style.pointerEvents = 'none'; }";
                    [self.webView evaluateJavaScript:js completionHandler:nil];
                }
            }
            decisionHandler(WKNavigationActionPolicyCancel);
            return;
        }


        if (targetUrlStr && targetUrlStr.length > 0) {
            if ([host isEqualToString:@"read-original"]) {
                appine_core_add_web_tab(targetUrlStr);
            } else if ([host isEqualToString:@"open-browser"]) {
                [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:targetUrlStr]];
            }
        }
        decisionHandler(WKNavigationActionPolicyCancel);
        return;
    }

    // 2. 拦截 org-protocol 协议
    else if ([url.scheme isEqualToString:@"org-protocol"]) {
        APPINE_LOG(@"[Appine-Web] 拦截到 org-protocol: %@", url.absoluteString);

        // 阻止 WKWebView 的默认加载行为，防止静默失败
        decisionHandler(WKNavigationActionPolicyCancel);

        // 通过 macOS 系统 API 抛出 URL。
        // 因为当前 Emacs 已经运行且（通常）注册了该协议，系统会瞬间将其路由回 Emacs 内部触发 Capture。
        [[NSWorkspace sharedWorkspace] openURL:url];
        return;
    }

    // 对于文章正文中的普通链接，点击时调用 Appine Core 新建一个 Web Tab 打开
    if (navigationAction.navigationType == WKNavigationTypeLinkActivated) {
        // [[NSWorkspace sharedWorkspace] openURL:url];
        appine_core_add_web_tab(url.absoluteString);    // 使用自带的 Web Backend 打开
        decisionHandler(WKNavigationActionPolicyCancel);
        return;
    }

    decisionHandler(WKNavigationActionPolicyAllow);
}

- (void)updateOrgFileForArticle:(RssArticle *)article {
    // 1. 动态计算 Org 文件路径 (因为从数据库读出的 article 没有 orgFilePath)
    NSString *filePath = article.orgFilePath;
    if (!filePath && article.feedUrl) {
        RssNode *node = [self nodeForUrl:article.feedUrl node:self.rootNode];
        filePath = [node orgFilePath];
    }

    if (!filePath || ![[NSFileManager defaultManager] fileExistsAtPath:filePath]) {
        APPINE_LOG(@"[Appine RSS] ⚠️ 找不到对应的 Org 文件路径: %@", filePath);
        return;
    }

    NSMutableString *content = [NSMutableString stringWithContentsOfFile:filePath encoding:NSUTF8StringEncoding error:nil];
    if (!content) return;

    // 2. 查找文章在 Org 文件中的位置
    NSString *idLine = [NSString stringWithFormat:@":ID: %@\n", article.articleId];
    NSRange idRange = [content rangeOfString:idLine];

    // 【兼容旧数据】如果按 ID 找不到（旧代码可能把 ID 写空了），尝试按 LINK 找
    if (idRange.location == NSNotFound && article.link.length > 0) {
        NSString *linkLine = [NSString stringWithFormat:@":LINK: %@\n", article.link];
        idRange = [content rangeOfString:linkLine];
    }

    // 3. 执行替换
    if (idRange.location != NSNotFound) {
        NSRange propStartRange = [content rangeOfString:@":PROPERTIES:" options:NSBackwardsSearch range:NSMakeRange(0, idRange.location)];
        if (propStartRange.location != NSNotFound) {
            NSRange endRange = [content rangeOfString:@":END:" options:0 range:NSMakeRange(idRange.location, content.length - idRange.location)];
            if (endRange.location != NSNotFound) {
                NSRange propBlockRange = NSMakeRange(propStartRange.location, endRange.location - propStartRange.location);

                // 3.1 先用正则无情清理掉旧的 STARRED 和 IS_READ 属性（如果存在的话）
                NSRegularExpression *starRegex = [NSRegularExpression regularExpressionWithPattern:@":STARRED:.*\\n" options:0 error:nil];
                [starRegex replaceMatchesInString:content options:0 range:propBlockRange withTemplate:@""];

                // 重新计算 Range，因为字符串长度变了
                endRange = [content rangeOfString:@":END:" options:0 range:NSMakeRange(idRange.location, content.length - idRange.location)];
                propBlockRange = NSMakeRange(propStartRange.location, endRange.location - propStartRange.location);

                NSRegularExpression *readRegex = [NSRegularExpression regularExpressionWithPattern:@":IS_READ:.*\\n" options:0 error:nil];
                [readRegex replaceMatchesInString:content options:0 range:propBlockRange withTemplate:@""];

                // 3.2 重新计算最终的 :END: 位置，并插入最新的状态
                endRange = [content rangeOfString:@":END:" options:0 range:NSMakeRange(idRange.location, content.length - idRange.location)];
                NSMutableString *newProps = [NSMutableString string];
                if (article.isStarred) [newProps appendString:@":STARRED: 1\n"];
                if (article.isRead) [newProps appendString:@":IS_READ: 1\n"];

                [content insertString:newProps atIndex:endRange.location];

                [content writeToFile:filePath atomically:YES encoding:NSUTF8StringEncoding error:nil];
                APPINE_LOG(@"[Appine RSS] ✅ 成功同步 Org 文件属性 (STARRED: %d, IS_READ: %d)", article.isStarred, article.isRead);
            }
        }
    } else {
        APPINE_LOG(@"[Appine RSS] ⚠️ 未在 Org 文件中找到对应的文章节点: ID=%@, LINK=%@", article.articleId, article.link);
    }
}

@end

// 暴露给核心调用的 C 函数
id<AppineBackend> appine_create_rss_backend(NSString *path) {
    return [[AppineRssBackend alloc] initWithPath:path];
}

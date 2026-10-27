#import "HOWebView.h"

@class HOStatusBar;
@class HOJSBridge;

@interface HOBrowserView : NSView <WKNavigationDelegate, WKUIDelegate>
- (instancetype)initWithFrame:(NSRect)aRect configuration:(WKWebViewConfiguration*)aConfiguration;
- (void)loadURL:(NSURL*)aURL;
- (void)openTxMtURL:(NSURL*)aURL; // Subclasses can override to add parameters

@property (nonatomic, readonly) HOWebView* webView;
@property (nonatomic, readonly) HOJSBridge* bridge;
@property (nonatomic, readonly) BOOL needsNewWebView;
@property (nonatomic, readonly) HOStatusBar* statusBar;
@property (nonatomic) BOOL disableJavaScriptAPI;
@end

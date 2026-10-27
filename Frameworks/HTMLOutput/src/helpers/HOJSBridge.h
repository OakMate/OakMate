#import <WebKit/WebKit.h>

@protocol HOJSBridgeDelegate
@property (nonatomic, getter = isBusy) BOOL busy;
@property (nonatomic) double progress;
@end

// Implements the native side of the ‘TextMate’ JavaScript object (see HTMLOutputBridge.js)
@interface HOJSBridge : NSObject <WKScriptMessageHandler>
+ (WKUserScript*)userScript;

- (instancetype)initWithWebView:(WKWebView*)aWebView;

@property (nonatomic, weak) id <HOJSBridgeDelegate> delegate;
@property (nonatomic) std::map<std::string, std::string> environment;
@property (nonatomic, getter = isEnabled) BOOL enabled;

// Returns NO if the prompt was not sent by the bridge
- (BOOL)handlePrompt:(NSString*)prompt defaultText:(NSString*)defaultText frame:(WKFrameInfo*)frame completionHandler:(void(^)(NSString*))completionHandler;
- (void)cancelAllCommands;
@end

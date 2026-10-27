#import "HOBrowserView.h"
#import "HOStatusBar.h"
#import "../helpers/HOJSBridge.h"
#import <OakAppKit/NSAlert Additions.h>
#import <OakAppKit/OakUIConstructionFunctions.h>
#import <io/path.h>

static NSString* const kUserDefaultsDefaultURLProtocolKey = @"defaultURLProtocol";

static NSString* EscapeHTML (NSString* str)
{
	return [[[str stringByReplacingOccurrencesOfString:@"&" withString:@"&amp;"] stringByReplacingOccurrencesOfString:@"<" withString:@"&lt;"] stringByReplacingOccurrencesOfString:@"\"" withString:@"&quot;"];
}

static BOOL IsProtocolRelativeURL (NSURL* url)
{
	// If host has a dot and does not exist on disk then treat as protocol-relative URL
	return [url.scheme isEqualToString:@"file"] && [url.host containsString:@"."] && ![NSFileManager.defaultManager fileExistsAtPath:[@"/" stringByAppendingPathComponent:url.host]];
}

// Rewrite tm-file: and protocol-relative URLs and redirect missing files to an error page, returns nil if no change is needed
static NSURL* RedirectURL (NSURL* url)
{
	NSURL* res = nil;
	if([url.scheme isEqualToString:@"tm-file"])
	{
		NSURLComponents* components = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:YES];
		components.scheme = @"file";
		components.host   = nil;
		res = url = components.URL;
	}

	if(IsProtocolRelativeURL(url))
	{
		NSURLComponents* components = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:YES];
		components.scheme = [NSUserDefaults.standardUserDefaults stringForKey:kUserDefaultsDefaultURLProtocolKey];
		return components.URL;
	}

	if(url.isFileURL)
	{
		struct stat buf;
		char const* path = url.fileSystemRepresentation;
		if(path && stat(path, &buf) == 0)
		{
			if(S_ISDIR(buf.st_mode) && path::exists(path::join(path, "index.html")))
			{
				NSURLComponents* components = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:YES];
				components.path = [components.path stringByAppendingPathComponent:@"index.html"];
				res = components.URL;
			}
		}
		else if(NSURL* errorPage = [[NSBundle bundleForClass:[HOBrowserView class]] URLForResource:@"error_not_found" withExtension:@"html"])
		{
			NSURLComponents* components = [NSURLComponents componentsWithURL:errorPage resolvingAgainstBaseURL:YES];
			components.queryItems = @[ [NSURLQueryItem queryItemWithName:@"path" value:url.path], [NSURLQueryItem queryItemWithName:@"error" value:@"1"] ];
			res = components.URL;
		}
	}
	return res;
}

// Forward console messages and errors to the system log and show link targets in the status bar
static NSString* const kHelperScript = @"(function () {"
	"	const post = (command, payload) => window.webkit.messageHandlers.textmate.postMessage({ command: command, payload: payload });"
	"	for(const level of [ 'log', 'info', 'warn', 'error' ]) {"
	"		const original = console[level];"
	"		console[level] = function (...args) { post('console', { message: args.map(String).join(' ') }); return original.apply(console, args); };"
	"	}"
	"	window.addEventListener('error', (event) => post('console', { message: `${event.message} (${event.filename}:${event.lineno})` }));"
	"})();";

static NSString* const kStatusScript = @"(function () {"
	"	let current = null;"
	"	const update = (url) => { if(url !== current) window.webkit.messageHandlers.status.postMessage(current = url); };"
	"	window.addEventListener('mouseover', (event) => { const link = event.target.closest && event.target.closest('a[href]'); update(link ? link.href : ''); }, true);"
	"	window.addEventListener('mouseout', (event) => { if(!event.relatedTarget) update(''); }, true);"
	"})();";

@interface HOStatusBar (BusyAndProgressProperties) <HOJSBridgeDelegate>
@end

@interface HOBrowserView () <WKScriptMessageHandler>
@property (nonatomic, readwrite) HOWebView* webView;
@property (nonatomic, readwrite) HOJSBridge* bridge;
@property (nonatomic, readwrite) HOStatusBar* statusBar;
@property (nonatomic, readwrite) BOOL needsNewWebView;
@end

@implementation HOBrowserView
+ (void)initialize
{
	[NSUserDefaults.standardUserDefaults registerDefaults:@{
		kUserDefaultsDefaultURLProtocolKey: @"https",
	}];
}

+ (WKWebViewConfiguration*)defaultConfiguration
{
	WKWebViewConfiguration* config = [[WKWebViewConfiguration alloc] init];
	config.preferences.javaScriptCanOpenWindowsAutomatically = YES;
	@try {
		// Bundle commands load resources from disk and are allowed to use XMLHttpRequest for file: URLs
		[config.preferences setValue:@YES forKey:@"allowFileAccessFromFileURLs"];
		[config setValue:@YES forKey:@"allowUniversalAccessFromFileURLs"];
	}
	@catch(NSException* e) {
		os_log_error(OS_LOG_DEFAULT, "Unable to allow file access for file URLs: %{public}@", e.reason);
	}
	return config;
}

- (instancetype)initWithFrame:(NSRect)aRect
{
	return [self initWithFrame:aRect configuration:[HOBrowserView defaultConfiguration]];
}

- (instancetype)initWithFrame:(NSRect)aRect configuration:(WKWebViewConfiguration*)aConfiguration
{
	if(self = [super initWithFrame:aRect])
	{
		_webView = [[HOWebView alloc] initWithFrame:NSZeroRect configuration:aConfiguration];
		_webView.navigationDelegate = self;
		_webView.UIDelegate         = self;
		_webView.allowsBackForwardNavigationGestures = YES;
		_webView.allowsMagnification = YES;
		_webView.inspectable         = YES;

		_statusBar = [[HOStatusBar alloc] initWithFrame:NSZeroRect];
		_statusBar.delegate = _webView;

		_bridge = [[HOJSBridge alloc] initWithWebView:_webView];
		_bridge.delegate = _statusBar;
		_bridge.enabled  = YES;

		WKUserContentController* controller = _webView.configuration.userContentController;
		[controller removeAllScriptMessageHandlers];
		[controller addScriptMessageHandler:_bridge contentWorld:WKContentWorld.pageWorld name:@"textmate"];
		[controller addScriptMessageHandler:self contentWorld:WKContentWorld.defaultClientWorld name:@"status"];
		[self updateUserScripts];

		for(NSString* keyPath in @[ @"estimatedProgress", @"loading", @"canGoBack", @"canGoForward" ])
			[_webView addObserver:self forKeyPath:keyPath options:NSKeyValueObservingOptionInitial context:nullptr];

		NSDictionary* views = @{
			@"webView":   _webView,
			@"statusBar": _statusBar
		};

		OakAddAutoLayoutViewsToSuperview([views allValues], self);

		[self addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"H:|[webView(>=10)]|"            options:0                                                      metrics:nil views:views]];
		[self addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"V:|[webView(>=10)][statusBar]|" options:NSLayoutFormatAlignAllLeft|NSLayoutFormatAlignAllRight metrics:nil views:views]];
	}
	return self;
}

- (void)dealloc
{
	for(NSString* keyPath in @[ @"estimatedProgress", @"loading", @"canGoBack", @"canGoForward" ])
		[_webView removeObserver:self forKeyPath:keyPath];

	WKUserContentController* controller = _webView.configuration.userContentController;
	[controller removeAllScriptMessageHandlers];
	[controller removeAllUserScripts];

	_webView.navigationDelegate = nil;
	_webView.UIDelegate         = nil;
	[_webView stopLoading];
	[_bridge cancelAllCommands];
}

- (void)updateUserScripts
{
	WKUserContentController* controller = _webView.configuration.userContentController;
	[controller removeAllUserScripts];
	[controller addUserScript:[[WKUserScript alloc] initWithSource:kHelperScript injectionTime:WKUserScriptInjectionTimeAtDocumentStart forMainFrameOnly:NO inContentWorld:WKContentWorld.pageWorld]];
	[controller addUserScript:[[WKUserScript alloc] initWithSource:kStatusScript injectionTime:WKUserScriptInjectionTimeAtDocumentStart forMainFrameOnly:YES inContentWorld:WKContentWorld.defaultClientWorld]];
	if(!_disableJavaScriptAPI)
		[controller addUserScript:HOJSBridge.userScript];
}

- (void)setDisableJavaScriptAPI:(BOOL)flag
{
	if(_disableJavaScriptAPI == flag)
		return;
	_disableJavaScriptAPI = flag;
	_bridge.enabled = !flag;
	[self updateUserScripts];
}

- (void)loadURL:(NSURL*)aURL
{
	if(NSURL* redirectURL = RedirectURL(aURL))
		aURL = redirectURL;

	if(aURL.isFileURL)
			[_webView loadFileURL:aURL allowingReadAccessToURL:[NSURL fileURLWithPath:@"/"]];
	else	[_webView loadRequest:[NSURLRequest requestWithURL:aURL]];
}

- (void)observeValueForKeyPath:(NSString*)keyPath ofObject:(id)object change:(NSDictionary*)change context:(void*)context
{
	if([keyPath isEqualToString:@"estimatedProgress"])
	{
		_statusBar.progress = _webView.isLoading ? _webView.estimatedProgress : 0;
	}
	else if([keyPath isEqualToString:@"loading"])
	{
		_statusBar.busy = _webView.isLoading;
		if(!_webView.isLoading)
			_statusBar.progress = 0;
	}
	else if([keyPath isEqualToString:@"canGoBack"])
	{
		_statusBar.canGoBack = _webView.canGoBack;
	}
	else if([keyPath isEqualToString:@"canGoForward"])
	{
		_statusBar.canGoForward = _webView.canGoForward;
	}
}

- (void)userContentController:(WKUserContentController*)userContentController didReceiveScriptMessage:(WKScriptMessage*)message
{
	if([message.name isEqualToString:@"status"] && [message.body isKindOfClass:[NSString class]])
		_statusBar.statusText = [message.body stringByRemovingPercentEncoding] ?: message.body;
}

// ==============
// = Key Events =
// ==============

/*
Since the webView is typically the first responder, the path for key events is as follows:

For keyDown:
	webView
	HOBrowserView
	OakHTMLOutputView
	NSWindow

For performKeyEquivalent:
	NSWindow
	OakHTMLOutputView
	HOBrowserView
	webView

A webView default implementation passes all key events, including potential key equivalents (except ESC),
to the webpage so that it may have a chance to respond. Unfortunately, we cannot know if these events are
handled so the events are still forwarded down their respective chains as shown above. So to avoid the
NSBeep when hitting the end of the responder chain, we let HOBrowserView swallow all key events.
*/

- (void)keyDown:(NSEvent*)anEvent
{
}

// ===========================
// = WKNavigationDelegate =
// ===========================

- (void)webView:(WKWebView*)webView decidePolicyForNavigationAction:(WKNavigationAction*)navigationAction decisionHandler:(void(^)(WKNavigationActionPolicy))decisionHandler
{
	NSURL* url = navigationAction.request.URL;
	if(navigationAction.targetFrame.isMainFrame)
	{
		if(NSURL* redirectURL = RedirectURL(url))
		{
			decisionHandler(WKNavigationActionPolicyCancel);
			[self loadURL:redirectURL];
			return;
		}
	}

	if([WKWebView handlesURLScheme:url.scheme])
		return decisionHandler(WKNavigationActionPolicyAllow);

	decisionHandler(WKNavigationActionPolicyCancel);
	if([url.scheme isEqualToString:@"txmt"])
		[self openTxMtURL:url];
	else if(![url.scheme isEqualToString:@"tm-file"])
		[NSWorkspace.sharedWorkspace openURL:url];
}

- (void)openTxMtURL:(NSURL*)url
{
	[NSApp sendAction:@selector(handleTxMtURL:) to:nil from:url];
}

- (void)webView:(WKWebView*)webView decidePolicyForNavigationResponse:(WKNavigationResponse*)navigationResponse decisionHandler:(void(^)(WKNavigationResponsePolicy))decisionHandler
{
	if(navigationResponse.canShowMIMEType || !navigationResponse.isForMainFrame)
		return decisionHandler(WKNavigationResponsePolicyAllow);

	// Hand content WebKit cannot show to the system (as WebView did)
	decisionHandler(WKNavigationResponsePolicyCancel);
	[NSWorkspace.sharedWorkspace openURL:navigationResponse.response.URL];
}

- (void)webView:(WKWebView*)webView didCommitNavigation:(WKNavigation*)navigation
{
	[_bridge cancelAllCommands];
}

- (void)showLoadError:(NSError*)error
{
	if([error.domain isEqualToString:NSURLErrorDomain] && error.code == NSURLErrorCancelled)
		return;
	if([error.domain isEqualToString:WKErrorDomain] && error.code == 102) // Frame load interrupted
		return;

	NSURL* url = error.userInfo[NSURLErrorFailingURLErrorKey] ?: _webView.URL;
	NSString* options  = [[url scheme] isEqualToString:@"file"] ? @" -R" : @"";
	NSString* errorMsg = [NSString stringWithFormat:@"<title>Load Error</title><h1>Load Error</h1><p>WebKit reported <em>%@</em> while loading <tt><a href=\"#\" onClick=\"javascript:OakMate.system('/usr/bin/open%@ &quot;%@&quot;', null)\">%@</a></tt>.</p>", EscapeHTML([error localizedDescription]), options, EscapeHTML([url absoluteString]), EscapeHTML([url absoluteString])];
	[_webView loadHTMLString:errorMsg baseURL:[NSURL fileURLWithPath:NSTemporaryDirectory()]];
}

- (void)webView:(WKWebView*)webView didFailProvisionalNavigation:(WKNavigation*)navigation withError:(NSError*)error
{
	[self showLoadError:error];
}

- (void)webView:(WKWebView*)webView didFailNavigation:(WKNavigation*)navigation withError:(NSError*)error
{
	[self showLoadError:error];
}

// ====================
// = WKUIDelegate =
// ====================

- (void)webView:(WKWebView*)webView runJavaScriptAlertPanelWithMessage:(NSString*)message initiatedByFrame:(WKFrameInfo*)frame completionHandler:(void(^)())completionHandler
{
	NSAlert* alert = [NSAlert tmAlertWithMessageText:NSLocalizedString(@"Script Message", @"JavaScript alert title") informativeText:message buttons:NSLocalizedString(@"OK", @"JavaScript alert confirmation"), nil];
	if(webView.window)
			[alert beginSheetModalForWindow:webView.window completionHandler:^(NSModalResponse){ completionHandler(); }];
	else	[alert runModal], completionHandler();
}

- (void)webView:(WKWebView*)webView runJavaScriptConfirmPanelWithMessage:(NSString*)message initiatedByFrame:(WKFrameInfo*)frame completionHandler:(void(^)(BOOL))completionHandler
{
	NSAlert* alert        = [[NSAlert alloc] init];
	alert.messageText     = NSLocalizedString(@"Script Message", @"JavaScript alert title");
	alert.informativeText = message;
	[alert addButtons:NSLocalizedString(@"OK", @"JavaScript alert confirmation"), NSLocalizedString(@"Cancel", @"JavaScript alert cancel"), nil];
	completionHandler([alert runModal] == NSAlertFirstButtonReturn);
}

- (void)webView:(WKWebView*)webView runJavaScriptTextInputPanelWithPrompt:(NSString*)prompt defaultText:(NSString*)defaultText initiatedByFrame:(WKFrameInfo*)frame completionHandler:(void(^)(NSString*))completionHandler
{
	if([_bridge handlePrompt:prompt defaultText:defaultText frame:frame completionHandler:completionHandler])
		return;

	NSTextField* textField = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 300, 22)];
	textField.stringValue = defaultText ?: @"";

	NSAlert* alert        = [[NSAlert alloc] init];
	alert.messageText     = NSLocalizedString(@"Script Message", @"JavaScript alert title");
	alert.informativeText = prompt;
	alert.accessoryView   = textField;
	[alert addButtons:NSLocalizedString(@"OK", @"JavaScript alert confirmation"), NSLocalizedString(@"Cancel", @"JavaScript alert cancel"), nil];
	[alert layout];
	[alert.window makeFirstResponder:textField];
	completionHandler([alert runModal] == NSAlertFirstButtonReturn ? textField.stringValue : nil);
}

- (void)webView:(WKWebView*)webView runOpenPanelWithParameters:(WKOpenPanelParameters*)parameters initiatedByFrame:(WKFrameInfo*)frame completionHandler:(void(^)(NSArray<NSURL*>*))completionHandler
{
	NSOpenPanel* panel = [NSOpenPanel openPanel];
	panel.directoryURL            = [NSURL fileURLWithPath:NSHomeDirectory()];
	panel.allowsMultipleSelection = parameters.allowsMultipleSelection;
	panel.canChooseDirectories    = parameters.allowsDirectories;
	completionHandler([panel runModal] == NSModalResponseOK ? panel.URLs : nil);
}

- (WKWebView*)webView:(WKWebView*)webView createWebViewWithConfiguration:(WKWebViewConfiguration*)configuration forNavigationAction:(WKNavigationAction*)navigationAction windowFeatures:(WKWindowFeatures*)windowFeatures
{
	NSPoint origin = [webView.window cascadeTopLeftFromPoint:NSMakePoint(NSMinX(webView.window.frame), NSMaxY(webView.window.frame))];
	origin.y -= NSHeight(webView.window.frame);

	HOBrowserView* view = [[HOBrowserView alloc] initWithFrame:NSZeroRect configuration:configuration];
	view.disableJavaScriptAPI = _disableJavaScriptAPI;
	view.bridge.environment   = _bridge.environment;

	NSWindow* window = [[NSWindow alloc] initWithContentRect:(NSRect){ origin, NSMakeSize(750, 800) } styleMask:(NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskResizable|NSWindowStyleMaskMiniaturizable) backing:NSBackingStoreBuffered defer:NO];
	[window bind:NSTitleBinding toObject:view.webView withKeyPath:@"title" options:@{ NSNullPlaceholderBindingOption: @"" }];
	[window setContentView:view];
	[window setReleasedWhenClosed:NO];
	[window makeKeyAndOrderFront:self];

	// Keep window (and view) alive until it is closed
	__block id token = [NSNotificationCenter.defaultCenter addObserverForName:NSWindowWillCloseNotification object:window queue:nil usingBlock:^(NSNotification*){
		[window unbind:NSTitleBinding];
		[NSNotificationCenter.defaultCenter removeObserver:token];
		token = nil;
	}];

	return view.webView;
}

- (void)webViewDidClose:(WKWebView*)webView
{
	if(![webView tryToPerform:@selector(toggleHTMLOutput:) with:self])
		[webView.window performClose:self];
	self.needsNewWebView = YES;
}
@end

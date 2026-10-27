#import "OakHTMLOutputView.h"
#import "browser/HOStatusBar.h"
#import "helpers/HOJSBridge.h"
#import <text/utf8.h>
#import <OakFoundation/OakFoundation.h>
#import <OakFoundation/NSString Additions.h>
#import <OakAppKit/NSAlert Additions.h>
#import <OakSystem/process.h>
#import <ns/ns.h>
#import <oak/debug.h>

// Command output is streamed into an (empty) page loaded from disk using document.write(). This
// gives the output a file: origin so that it can reference resources on disk (WKWebView has no
// way to stream a response from a custom URL scheme handler with a file: origin).
static NSString* const kWriteOutputScript =
	@"if(first)"
	@"	document.open();"
	@"const root = document.scrollingElement || document.documentElement;"
	@"const pinned = autoScroll && (!root || window.innerHeight + window.scrollY >= root.scrollHeight - 16);"
	@"document.write(html);"
	@"if(pinned)"
	@"	window.scrollTo(0, document.documentElement.scrollHeight);"
	@"if(last) {"
	@"	document.close();"
	@"	if(scrollPosition !== null)"
	@"		window.scrollTo(0, scrollPosition);"
	@"}";

@interface OakHTMLOutputView ()
{
	NSUInteger _outputGeneration;
	std::string _pendingOutput;
}
@property (nonatomic, getter = isRunningCommand, readwrite) BOOL runningCommand;
@property (nonatomic) NSURLRequest* currentRequest;
@property (nonatomic) std::map<std::string, std::string> environment;
@property (nonatomic, getter = isVisible) BOOL visible;

@property (nonatomic) BOOL autoScrolls;
@property (nonatomic) WKNavigation* outputNavigation;
@property (nonatomic) BOOL outputPageLoaded;
@property (nonatomic) BOOL outputStarted;
@property (nonatomic) BOOL outputComplete;
@property (nonatomic) BOOL writeInProgress;
@property (nonatomic) NSNumber* scrollPositionToRestore;
@end

@implementation OakHTMLOutputView
+ (NSSet*)keyPathsForValuesAffectingMainFrameTitle
{
	return [NSSet setWithObjects:@"webView.title", @"currentRequest", nil];
}

+ (NSURL*)outputPageURL
{
	return [[NSBundle bundleForClass:self] URLForResource:@"HTMLOutput" withExtension:@"html"];
}

- (instancetype)initWithFrame:(NSRect)aRect
{
	if(self = [super initWithFrame:aRect])
	{
		_reusable = YES;
	}
	return self;
}

- (void)setEnvironment:(std::map<std::string, std::string>)anEnvironment
{
	_environment = anEnvironment;
	self.bridge.environment = anEnvironment;
}

- (void)loadRequest:(NSURLRequest*)aRequest environment:(std::map<std::string, std::string> const&)anEnvironment autoScrolls:(BOOL)flag
{
	self.environment       = anEnvironment;
	self.commandIdentifier = [NSURLProtocol propertyForKey:@"commandIdentifier" inRequest:aRequest];
	self.runningCommand    = self.commandIdentifier != nil;
	self.currentRequest    = aRequest;

	if(NSFileHandle* fileHandle = [NSURLProtocol propertyForKey:@"fileHandle" inRequest:aRequest])
	{
		[self beginOutputWithAutoScroll:flag];

		NSUInteger generation = _outputGeneration;
		int fd = fileHandle.fileDescriptor;
		dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
			char buf[8192];
			ssize_t len;
			while((len = read(fd, buf, sizeof(buf))) > 0)
			{
				std::string data(buf, buf + len);
				dispatch_async(dispatch_get_main_queue(), ^{
					[self appendOutput:data generation:generation];
				});
			}

			if(len == -1)
				perror("HTMLOutput: read");
			[fileHandle closeFile];

			dispatch_async(dispatch_get_main_queue(), ^{
				[self finishOutputWithGeneration:generation];
			});
		});
	}
	else
	{
		[self loadURL:aRequest.URL];
	}
}

- (void)setContent:(NSString*)someHTML
{
	[self.webView evaluateJavaScript:@"window.scrollY" inFrame:nil inContentWorld:WKContentWorld.defaultClientWorld completionHandler:^(id res, NSError* error){
		[self beginOutputWithAutoScroll:NO];
		self.scrollPositionToRestore = [res isKindOfClass:[NSNumber class]] ? res : nil;
		[self appendOutput:to_s(someHTML) generation:_outputGeneration];
		[self finishOutputWithGeneration:_outputGeneration];
	}];
}

// ======================
// = Command HTML Output =
// ======================

- (void)beginOutputWithAutoScroll:(BOOL)flag
{
	++_outputGeneration;
	_pendingOutput.clear();

	self.autoScrolls             = flag;
	self.outputPageLoaded        = NO;
	self.outputStarted           = NO;
	self.outputComplete          = NO;
	self.writeInProgress         = NO;
	self.scrollPositionToRestore = nil;

	self.statusBar.busy = YES;
	self.outputNavigation = [self.webView loadFileURL:[OakHTMLOutputView outputPageURL] allowingReadAccessToURL:[NSURL fileURLWithPath:@"/"]];
}

- (void)appendOutput:(std::string const&)data generation:(NSUInteger)generation
{
	if(generation != _outputGeneration)
		return;
	_pendingOutput.insert(_pendingOutput.end(), data.begin(), data.end());
	[self writePendingOutput];
}

- (void)finishOutputWithGeneration:(NSUInteger)generation
{
	if(generation != _outputGeneration)
		return;
	self.outputComplete = YES;
	[self writePendingOutput];
}

- (void)writePendingOutput
{
	if(!self.outputPageLoaded || self.writeInProgress)
		return;

	// Only write complete UTF-8 sequences
	auto end = utf8::find_safe_end(_pendingOutput.begin(), _pendingOutput.end());
	if(self.outputComplete)
		end = _pendingOutput.end();
	std::string str(_pendingOutput.begin(), end);
	_pendingOutput.erase(_pendingOutput.begin(), end);
	str.erase(utf8::remove_malformed(str.begin(), str.end()), str.end());

	BOOL last = self.outputComplete;
	if(str.empty() && !last && self.outputStarted)
		return;

	NSDictionary* arguments = @{
		@"html":           [NSString stringWithCxxString:str] ?: @"",
		@"first":          @(!self.outputStarted),
		@"last":           @(last),
		@"autoScroll":     @(self.autoScrolls),
		@"scrollPosition": self.scrollPositionToRestore ?: [NSNull null],
	};

	self.outputStarted   = YES;
	self.writeInProgress = YES;

	NSUInteger generation = _outputGeneration;
	[self.webView callAsyncJavaScript:kWriteOutputScript arguments:arguments inFrame:nil inContentWorld:WKContentWorld.defaultClientWorld completionHandler:^(id res, NSError* error){
		if(error)
			os_log_error(OS_LOG_DEFAULT, "Error writing HTML output: %{public}@", error);

		if(generation != _outputGeneration)
			return;

		self.writeInProgress = NO;
		if(last)
				[self didFinishOutput];
		else	[self writePendingOutput];
	}];
}

- (void)didFinishOutput
{
	++_outputGeneration;
	self.outputNavigation = nil;
	self.runningCommand   = NO;
	self.statusBar.busy   = NO;
}

- (void)cancelOutput
{
	if(!self.outputNavigation)
		return;

	// Navigating away from (or stopping) command output terminates the command
	if(self.isRunningCommand)
	{
		if(pid_t pid = [[NSURLProtocol propertyForKey:@"processIdentifier" inRequest:self.currentRequest] intValue])
			oak::kill_process_group_in_background(pid);
	}

	++_outputGeneration;
	_pendingOutput.clear();
	self.outputNavigation = nil;
	self.runningCommand   = NO;
	self.statusBar.busy   = NO;
	[self.webView evaluateJavaScript:@"document.close()" inFrame:nil inContentWorld:WKContentWorld.defaultClientWorld completionHandler:nil];
}

- (void)webView:(WKWebView*)webView didFinishNavigation:(WKNavigation*)navigation
{
	if(navigation && navigation == self.outputNavigation)
	{
		self.outputPageLoaded = YES;
		[self writePendingOutput];
	}
	else if(!self.outputNavigation)
	{
		self.runningCommand = NO;
	}
}

- (void)webView:(WKWebView*)webView didStartProvisionalNavigation:(WKNavigation*)navigation
{
	if(navigation != self.outputNavigation)
		[self cancelOutput];
}

- (void)webView:(WKWebView*)webView didFailProvisionalNavigation:(WKNavigation*)navigation withError:(NSError*)error
{
	if(navigation == self.outputNavigation)
		[self cancelOutput];
	self.runningCommand = NO;
	[super webView:webView didFailProvisionalNavigation:navigation withError:error];
}

// ==================
// = Stop / Title =
// ==================

- (void)stopLoadingWithUserInteraction:(BOOL)askUserFlag completionHandler:(void(^)(BOOL didStop))handler
{
	NSURLRequest* request = self.currentRequest;
	if(id command = [NSURLProtocol propertyForKey:@"command" inRequest:request])
	{
		NSAlert* alert = askUserFlag ? [NSAlert tmAlertWithMessageText:[NSString stringWithFormat:@"Stop “%@”?", [NSURLProtocol propertyForKey:@"processName" inRequest:request]] informativeText:@"The job that the task is performing will not be completed." buttons:@"Stop", @"Cancel", nil] : nil;

		__weak __block id token = [NSNotificationCenter.defaultCenter addObserverForName:@"OakCommandDidTerminateNotification" object:command queue:nil usingBlock:^(NSNotification* notification){
			if(alert)
				[self.window endSheet:alert.window returnCode:NSAlertFirstButtonReturn];
			handler(YES);
			[NSNotificationCenter.defaultCenter removeObserver:token];
		}];

		void(^stopCommand)() = ^{
			if(pid_t pid = [[NSURLProtocol propertyForKey:@"processIdentifier" inRequest:request] intValue])
				oak::kill_process_group_in_background(pid);
			self.runningCommand = NO;
			[self cancelOutput];
		};

		if(alert)
		{
			[alert beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse returnCode){
				if(returnCode == NSAlertFirstButtonReturn) /* "Stop" */
				{
					stopCommand();
				}
				else
				{
					handler(NO);
					[NSNotificationCenter.defaultCenter removeObserver:token];
				}
			}];
		}
		else
		{
			stopCommand();
		}
	}
	else
	{
		handler(YES);
	}
}

- (NSString*)mainFrameTitle
{
	if(OakIsEmptyString(self.webView.title))
		return [NSURLProtocol propertyForKey:@"processName" inRequest:self.currentRequest] ?: @"";
	return self.webView.title;
}

- (void)openTxMtURL:(NSURL*)url
{
	auto projectUUID = _environment.find("TM_PROJECT_UUID");
	if(projectUUID != _environment.end())
		url = [NSURL URLWithString:[[url absoluteString] stringByAppendingFormat:@"&project=%@", [NSString stringWithCxxString:projectUUID->second]]];
	[super openTxMtURL:url];
}

- (void)viewDidMoveToWindow
{
	[NSNotificationCenter.defaultCenter removeObserver:self name:NSWindowWillCloseNotification object:nil];
	if(self.window)
		[NSNotificationCenter.defaultCenter addObserver:self selector:@selector(windowWillClose:) name:NSWindowWillCloseNotification object:self.window];
	self.visible = self.window ? YES : NO;
}

- (void)windowWillClose:(NSNotification*)aNotification
{
	self.visible = NO;
}

// ====================
// = Printing Support =
// ====================

- (IBAction)printDocument:(id)sender
{
	NSPrintInfo* info = [NSPrintInfo.sharedPrintInfo copy];

	NSRect display = NSIntersectionRect(info.imageablePageBounds, (NSRect){ NSZeroPoint, info.paperSize });
	info.leftMargin   = NSMinX(display);
	info.rightMargin  = info.paperSize.width - NSMaxX(display);
	info.topMargin    = info.paperSize.height - NSMaxY(display);
	info.bottomMargin = NSMinY(display);

	NSPrintOperation* printer = [self.webView printOperationWithPrintInfo:info];
	printer.view.frame = self.webView.bounds;
	[[printer printPanel] setOptions:[[printer printPanel] options] | NSPrintPanelShowsPaperSize | NSPrintPanelShowsOrientation];
	[printer runOperationModalForWindow:self.window delegate:nil didRunSelector:NULL contextInfo:nil];
}
@end

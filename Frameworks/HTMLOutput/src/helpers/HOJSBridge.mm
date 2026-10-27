#import "HOJSBridge.h"
#import "add_to_buffer.h"
#import <OakAppKit/NSAlert Additions.h>
#import <OakFoundation/NSString Additions.h>
#import <document/OakDocument.h>
#import <document/OakDocumentController.h>
#import <text/utf8.h>
#import <ns/ns.h>
#import <io/exec.h>
#import <oak/debug.h>

static NSString* const kBridgePrompt = @"x-txmt-bridge";

// ====================
// = HOJSShellCommand =
// ====================

@interface HOJSShellCommand : NSObject
- (instancetype)initWithCommand:(NSString*)aCommand environment:(std::map<std::string, std::string> const&)someEnvironment outputHandler:(void(^)(BOOL isError, NSString* str))outputHandler exitHandler:(void(^)(int status, NSString* output, NSString* error))exitHandler;
- (void)writeToInput:(NSString*)someData;
- (void)closeInput;
- (void)cancel;
@property (nonatomic, readonly, getter = isRunning) BOOL running;
@end

@implementation HOJSShellCommand
{
	io::process_t _process;
	std::string _output, _error;
	void(^_outputHandler)(BOOL, NSString*);
	void(^_exitHandler)(int, NSString*, NSString*);
}

- (instancetype)initWithCommand:(NSString*)aCommand environment:(std::map<std::string, std::string> const&)someEnvironment outputHandler:(void(^)(BOOL isError, NSString* str))outputHandler exitHandler:(void(^)(int status, NSString* output, NSString* error))exitHandler
{
	if(self = [super init])
	{
		_outputHandler = outputHandler;
		_exitHandler   = exitHandler;

		if(_process = io::spawn(std::vector<std::string>{ "/bin/sh", "-c", to_s(aCommand) }, someEnvironment))
		{
			_running = YES;

			dispatch_group_t group = dispatch_group_create();
			[self exhaustFileDescriptor:_process.out group:group buffer:_output isError:NO];
			[self exhaustFileDescriptor:_process.err group:group buffer:_error isError:YES];

			__block int status = -1;
			pid_t pid = _process.pid;
			dispatch_group_async(group, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
				int result = 0;
				if(waitpid(pid, &result, 0) == pid)
						status = WIFEXITED(result) ? WEXITSTATUS(result) : -1;
				else	perror("HOJSShellCommand: waitpid");
			});

			dispatch_group_notify(group, dispatch_get_main_queue(), ^{
				close(_process.out);
				close(_process.err);
				[self closeInput];
				_process.pid = -1;
				_running = NO;

				if(auto handler = std::exchange(_exitHandler, nil))
					handler(status, [self stringFromBuffer:_output], [self stringFromBuffer:_error]);
				_outputHandler = nil;
			});

			if(!_outputHandler)
				[self closeInput];
		}
		else
		{
			dispatch_async(dispatch_get_main_queue(), ^{
				if(auto handler = std::exchange(_exitHandler, nil))
					handler(-1, @"", [NSString stringWithFormat:@"Failed to run ‘%@’.", aCommand]);
			});
		}
	}
	return self;
}

- (NSString*)stringFromBuffer:(std::string const&)buf
{
	return buf.empty() ? @"" : [[NSString alloc] initWithBytes:buf.data() length:utf8::find_safe_end(buf.begin(), buf.end()) - buf.begin() encoding:NSUTF8StringEncoding] ?: @"";
}

- (void)exhaustFileDescriptor:(int)fd group:(dispatch_group_t)group buffer:(std::string&)buf isError:(BOOL)isError
{
	dispatch_group_async(group, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
		char tmp[8192];
		while(ssize_t len = read(fd, &tmp[0], sizeof(tmp)))
		{
			if(len < 0)
				break;

			char const* bytes = &tmp[0];
			dispatch_sync(dispatch_get_main_queue(), ^{
				auto range = add_bytes_to_utf8_buffer(buf, bytes, bytes + len, _outputHandler != nil);
				if(_outputHandler && range.first != range.second)
					_outputHandler(isError, [NSString stringWithCxxString:std::string(range.first, range.second)]);
			});
		}
	});
}

- (void)writeToInput:(NSString*)someData
{
	if(_process.in != -1)
	{
		char const* bytes = [someData UTF8String];
		if(write(_process.in, bytes, strlen(bytes)) == -1)
			perror("HOJSShellCommand: write");
	}
}

- (void)closeInput
{
	if(_process.in != -1)
	{
		close(_process.in);
		_process.in = -1;
	}
}

- (void)cancel
{
	_outputHandler = nil;
	_exitHandler   = nil;

	[self closeInput];
	if(_process)
		kill(_process.pid, SIGINT);
}

- (void)dealloc
{
	[self cancel];
}
@end

// ============
// = HOJSBridge =
// ============

@interface HOJSBridge ()
@property (nonatomic, weak) WKWebView* webView;
@property (nonatomic) NSMutableDictionary<NSNumber*, HOJSShellCommand*>* commands;
@end

@implementation HOJSBridge
+ (WKUserScript*)userScript
{
	static WKUserScript* userScript;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		NSString* source;
		if(NSURL* url = [[NSBundle bundleForClass:self] URLForResource:@"HTMLOutputBridge" withExtension:@"js"])
			source = [NSString stringWithContentsOfURL:url encoding:NSUTF8StringEncoding error:nil];
		if(!source)
			os_log_error(OS_LOG_DEFAULT, "Unable to load HTMLOutputBridge.js");
		userScript = [[WKUserScript alloc] initWithSource:source ?: @"" injectionTime:WKUserScriptInjectionTimeAtDocumentStart forMainFrameOnly:YES];
	});
	return userScript;
}

- (instancetype)initWithWebView:(WKWebView*)aWebView
{
	if(self = [super init])
	{
		_webView  = aWebView;
		_commands = [NSMutableDictionary dictionary];
	}
	return self;
}

- (void)dealloc
{
	[self cancelAllCommands];
}

- (void)cancelAllCommands
{
	for(HOJSShellCommand* command in _commands.allValues)
		[command cancel];
	[_commands removeAllObjects];
}

- (BOOL)isTrustedFrame:(WKFrameInfo*)frame
{
	return _enabled && frame.isMainFrame && [frame.securityOrigin.protocol isEqualToString:@"file"];
}

- (void)sendCommandEvent:(NSNumber*)commandId type:(NSString*)type data:(id)data
{
	[_webView callAsyncJavaScript:@"if(window.TextMate) TextMate._commandEvent(id, type, data);" arguments:@{ @"id": commandId, @"type": type, @"data": data } inFrame:nil inContentWorld:WKContentWorld.pageWorld completionHandler:nil];
}

// ============================
// = WKScriptMessageHandler =
// ============================

- (void)userContentController:(WKUserContentController*)userContentController didReceiveScriptMessage:(WKScriptMessage*)message
{
	NSDictionary* body = [message.body isKindOfClass:[NSDictionary class]] ? message.body : nil;
	NSString* command  = body[@"command"];
	NSDictionary* payload = [body[@"payload"] isKindOfClass:[NSDictionary class]] ? body[@"payload"] : @{ };

	if([command isEqualToString:@"console"])
	{
		static os_log_t log = os_log_create("com.macromates.JavaScript", "HTMLOutput");
		os_log(log, "%{public}@: %{public}@", message.frameInfo.request.URL.absoluteString, payload[@"message"]);
		return;
	}

	if(![self isTrustedFrame:message.frameInfo])
	{
		os_log_error(OS_LOG_DEFAULT, "Ignoring JavaScript bridge message ‘%{public}@’ from %{public}@", command, message.frameInfo.request.URL.absoluteString);
		return;
	}

	if([command isEqualToString:@"log"])
	{
		NSLog(@"JavaScript Log: %@", payload[@"message"]);
	}
	else if([command isEqualToString:@"open"])
	{
		id options = payload[@"options"];
		text::range_t range = text::range_t::undefined;
		if([options isKindOfClass:[NSNumber class]])
			range = text::pos_t([options intValue]-1, 0);
		else if([options isKindOfClass:[NSString class]])
			range = to_s(options);

		if(NSString* path = payload[@"path"])
		{
			if(OakDocument* doc = [OakDocumentController.sharedInstance documentWithPath:path])
				[OakDocumentController.sharedInstance showDocument:doc andSelect:range inProject:nil bringToFront:YES];
		}
	}
	else if([command isEqualToString:@"setBusy"])
	{
		[_delegate setBusy:[payload[@"value"] boolValue]];
	}
	else if([command isEqualToString:@"setProgress"])
	{
		[_delegate setProgress:[payload[@"value"] doubleValue]];
	}
	else if([command isEqualToString:@"system"])
	{
		NSNumber* commandId = payload[@"id"];
		NSString* shellCommand = payload[@"command"];
		if(![commandId isKindOfClass:[NSNumber class]] || ![shellCommand isKindOfClass:[NSString class]])
			return;

		__weak HOJSBridge* weakSelf = self;
		_commands[commandId] = [[HOJSShellCommand alloc] initWithCommand:shellCommand environment:_environment outputHandler:^(BOOL isError, NSString* str){
			[weakSelf sendCommandEvent:commandId type:(isError ? @"error" : @"output") data:str];
		} exitHandler:^(int status, NSString* output, NSString* error){
			[weakSelf.commands removeObjectForKey:commandId];
			[weakSelf sendCommandEvent:commandId type:@"exit" data:@(status)];
		}];
	}
	else if([command isEqualToString:@"write"])
	{
		if(NSString* data = payload[@"data"])
			[_commands[payload[@"id"]] writeToInput:data];
	}
	else if([command isEqualToString:@"closeInput"])
	{
		[_commands[payload[@"id"]] closeInput];
	}
	else if([command isEqualToString:@"cancel"])
	{
		[_commands[payload[@"id"]] cancel];
		[_commands removeObjectForKey:payload[@"id"]];
	}
}

// ================================================
// = Synchronous calls (via window.prompt()) =
// ================================================

- (BOOL)handlePrompt:(NSString*)prompt defaultText:(NSString*)defaultText frame:(WKFrameInfo*)frame completionHandler:(void(^)(NSString*))completionHandler
{
	if(![prompt isEqualToString:kBridgePrompt])
		return NO;

	NSDictionary* request = [NSJSONSerialization JSONObjectWithData:[defaultText dataUsingEncoding:NSUTF8StringEncoding] ?: [NSData data] options:0 error:nil];
	NSString* shellCommand = [request isKindOfClass:[NSDictionary class]] && [request[@"command"] isEqual:@"system"] ? request[@"payload"][@"command"] : nil;
	if(![self isTrustedFrame:frame] || ![shellCommand isKindOfClass:[NSString class]])
	{
		completionHandler(nil);
		return YES;
	}

	__block BOOL didFinish = NO;
	__block void(^handler)(NSString*) = completionHandler;
	HOJSShellCommand* command = [[HOJSShellCommand alloc] initWithCommand:shellCommand environment:_environment outputHandler:nil exitHandler:^(int status, NSString* output, NSString* error){
		didFinish = YES;
		NSData* data = [NSJSONSerialization dataWithJSONObject:@{ @"outputString": output, @"errorString": error, @"status": @(status) } options:0 error:nil];
		if(auto fn = std::exchange(handler, nil))
			fn([[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]);
	}];

	// JavaScript is blocked until the command finishes, so periodically offer to stop it
	__block void(^checkCommand)() = ^{
		if(!didFinish)
		{
			NSAlert* alert        = [[NSAlert alloc] init];
			alert.messageText     = @"JavaScript Warning";
			alert.informativeText = [NSString stringWithFormat:@"The command ‘%@’ has been running for 15 seconds. Would you like to stop it?\n\nTo avoid this warning, the bundle command should use the asynchronous version of TextMate.system().", shellCommand];
			[alert addButtons:@"Stop Command", @"Cancel", nil];

			if([alert runModal] == NSAlertFirstButtonReturn) // "Stop Command"
			{
				[command cancel];
				if(auto fn = std::exchange(handler, nil))
					fn(nil);
			}
			else if(!didFinish)
			{
				dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC), dispatch_get_main_queue(), checkCommand);
				return;
			}
		}
		checkCommand = nil; // Break retain cycle
	};
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC), dispatch_get_main_queue(), checkCommand);

	return YES;
}
@end

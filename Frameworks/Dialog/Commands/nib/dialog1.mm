#import "../../TMDCommand.h"
#import "../prototype/TMDChameleon.h"
#import "TMDNibController.h"

// Dialog 1 was a separate plug-in with its own tool. Bundles still call it
// through "$DIALOG" with options instead of a command, e.g. TextMate::UI.dialog
// uses ‘-a’, ‘-t’, ‘-w’, and ‘-x’ for asynchronous windows. Those calls are
// handled here using the nib controller from Dialog 2.

std::string find_nib (std::string nibName, std::string currentDirectory, NSDictionary* env);

static int const kDialog1WindowNotFound = -43;

@interface TMDDialog1Command : TMDCommand
@end

@implementation TMDDialog1Command
+ (void)load
{
	[super registerObject:[self new] forCommand:@"x-dialog-1"];
}

static BOOL parse_options (NSArray* arguments, NSMutableDictionary* options, NSMutableArray* positional)
{
	static NSString* const kOptionsWithArgument = @"dnpxtw";
	static NSDictionary* const kLongOptions = @{
		@"alert":          @"e", @"center":        @"c", @"defaults":       @"d",
		@"new-items":      @"n", @"modal":         @"m", @"parameters":     @"p",
		@"quiet":          @"q", @"menu":          @"u", @"async-window":   @"a",
		@"close-window":   @"x", @"update-window": @"t", @"wait-for-input": @"w",
		@"list-windows":   @"l", @"help":          @"h",
	};

	for(NSUInteger i = 1; i < arguments.count; ++i)
	{
		NSString* arg = arguments[i];
		if([arg hasPrefix:@"--"] && arg.length > 2)
		{
			NSString* name  = [arg substringFromIndex:2];
			NSString* value = nil;

			NSRange equal = [name rangeOfString:@"="];
			if(equal.location != NSNotFound)
			{
				value = [name substringFromIndex:NSMaxRange(equal)];
				name  = [name substringToIndex:equal.location];
			}

			NSString* option = kLongOptions[name];
			if(!option)
				return NO;

			if([kOptionsWithArgument containsString:option])
			{
				if(!value && i+1 < arguments.count)
					value = arguments[++i];
				if(!value)
					return NO;
			}
			options[option] = value ?: @YES;
		}
		else if([arg hasPrefix:@"-"] && arg.length > 1)
		{
			for(NSUInteger j = 1; j < arg.length; ++j)
			{
				NSString* option = [arg substringWithRange:NSMakeRange(j, 1)];
				if(![kLongOptions.allValues containsObject:option])
					return NO;

				if([kOptionsWithArgument containsString:option])
				{
					NSString* value = j+1 < arg.length ? [arg substringFromIndex:j+1] : (i+1 < arguments.count ? arguments[++i] : nil);
					if(!value)
						return NO;
					options[option] = value;
					break;
				}
				options[option] = @YES;
			}
		}
		else
		{
			[positional addObject:arg];
		}
	}
	return YES;
}

static id property_list (NSString* string)
{
	if(!string)
		return nil;
	return [NSPropertyListSerialization propertyListWithData:[string dataUsingEncoding:NSUTF8StringEncoding] options:NSPropertyListMutableContainersAndLeaves format:nil error:nil];
}

- (void)handleCommand:(CLIProxy*)proxy
{
	NSMutableArray* arguments = [NSMutableArray array];
	for(NSUInteger i = 0; i < proxy.numberOfArguments; ++i)
		[arguments addObject:[proxy argumentAtIndex:i]];

	NSMutableDictionary* options = [NSMutableDictionary dictionary];
	NSMutableArray* positional   = [NSMutableArray array];
	if(!parse_options(arguments, options, positional) || options[@"h"])
	{
		[proxy writeStringToError:@"This is the Dialog 1 interface, which only supports windows from nibs. For the current interface run: \"$DIALOG\" help\n"];
		proxy.exitStatus = options[@"h"] ? EX_OK : EX_USAGE;
		return;
	}

	if(options[@"u"] || options[@"e"])
	{
		[proxy writeStringToError:[NSString stringWithFormat:@"The Dialog 1 %@ option is no longer supported, instead use: \"$DIALOG\" %@\n", options[@"u"] ? @"menu" : @"alert", options[@"u"] ? @"menu" : @"alert"]];
		proxy.exitStatus = EX_USAGE;
		return;
	}

	if(options[@"l"])
	{
		for(TMDNibController* nibController in [TMDNibController controllers])
			[proxy writeStringToOutput:[NSString stringWithFormat:@"%@ (%@)\n", nibController.token, nibController.window.title.length ? nibController.window.title : @"<no title>"]];
		return;
	}

	NSString* token = options[@"x"] ?: options[@"t"] ?: options[@"w"];
	if(token)
	{
		TMDNibController* nibController = [TMDNibController controllerForToken:token];
		if(!nibController)
		{
			[proxy writeStringToError:[NSString stringWithFormat:@"Window ‘%@’ doesn’t exist\n", token]];
			proxy.exitStatus = kDialog1WindowNotFound;
		}
		else if(options[@"x"])
		{
			[nibController.window orderOut:self];
			[nibController tearDown];
		}
		else if(options[@"t"])
		{
			if(id plist = property_list(options[@"p"]) ?: [TMDCommand readPropertyList:proxy.inputHandle error:nil])
				[nibController updateParametersWith:plist];
		}
		else
		{
			[nibController addClientFileHandle:proxy.outputHandle modal:NO];
		}
		return;
	}

	if(positional.count != 1)
	{
		[proxy writeStringToError:@"No nib given\n"];
		proxy.exitStatus = EX_USAGE;
		return;
	}

	NSString* nib = @(find_nib([positional.firstObject UTF8String], proxy.workingDirectory.UTF8String ?: "", proxy.environment).c_str());
	if(nib.length == 0)
	{
		[proxy writeStringToError:[NSString stringWithFormat:@"nib could not be loaded: %@ (does not exist)\n", positional.firstObject]];
		proxy.exitStatus = EX_NOINPUT;
		return;
	}

	if(NSDictionary* defaults = property_list(options[@"d"]))
		[NSUserDefaults.standardUserDefaults registerDefaults:defaults];

	NSDictionary* dynamicClasses = property_list(options[@"n"]);
	for(NSString* name in dynamicClasses)
		[TMD2Chameleon createSubclassNamed:name withValues:dynamicClasses[name]];

	TMDNibController* nibController = [[TMDNibController alloc] initWithNibPath:nib];
	if(!nibController)
	{
		[proxy writeStringToError:[NSString stringWithFormat:@"Error creating window from %@\n", nib]];
		proxy.exitStatus = EX_DATAERR;
		return;
	}

	BOOL async = options[@"a"] ? YES : NO;
	nibController.dialog1Results      = YES;
	nibController.dialog1Async        = async;
	nibController.tearDownAfterReturn = !async;

	if(id plist = property_list(options[@"p"]) ?: [TMDCommand readPropertyList:proxy.inputHandle error:nil])
		[nibController updateParametersWith:plist];
	[nibController showWindowAndCenter:options[@"c"] ? YES : NO];

	if(async)
			[proxy writeStringToOutput:[nibController.token stringByAppendingString:@"\n"]];
	else	[nibController addClientFileHandle:(options[@"q"] ? NSFileHandle.fileHandleWithNullDevice : proxy.outputHandle) modal:options[@"m"] ? YES : NO];
}

- (NSString*)commandDescription
{
	return @"Options of the Dialog 1 tool, e.g. ‘-a’ to show an asynchronous window.";
}

- (NSString*)usageForInvocation:(NSString*)invocation;
{
	return @"\"$DIALOG\" [-cdnmqp] «nib»\n\"$DIALOG\" -a [-cdnp] «nib»\n\"$DIALOG\" -t «token» [-p «plist»]\n\"$DIALOG\" -w «token»\n\"$DIALOG\" -x «token»\n\"$DIALOG\" -l\n";
}
@end

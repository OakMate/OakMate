//
//  Dialog2.mm
//  Dialog2
//
//  Created by Ciaran Walsh on 19/11/2007.
//

#import "Dialog2.h"
#import "TMDCommand.h"
#import "CLIProxy.h"
#import <ipc/ipc.h>

@protocol TMPlugInController
- (CGFloat)version;
@end

@interface Dialog2 : NSObject
- (id)initWithPlugInController:(id <TMPlugInController>)aController;
@end

@implementation Dialog2
- (id)initWithPlugInController:(id <TMPlugInController>)aController
{
	NSApp = NSApplication.sharedApplication;
	if(self = [self init])
	{
		std::string const socketPath = ipc::socket_path([NSString stringWithFormat:@"%@.%d.dialog", NSBundle.mainBundle.bundleIdentifier, getpid()].UTF8String);

		BOOL didListen = ipc::listen(socketPath, ^(int connection, std::string const& message, std::vector<int> const& fds){
			NSDictionary* options = [NSPropertyListSerialization propertyListWithData:[NSData dataWithBytes:message.data() length:message.size()] options:NSPropertyListImmutable format:nil error:nil];
			if(fds.size() == 3 && [options isKindOfClass:[NSDictionary class]])
			{
				int inputFd = fds[0], outputFd = fds[1], errorFd = fds[2]; // Blocks capture C++ references by reference
				dispatch_async(dispatch_get_main_queue(), ^{
					[self dispatch:[[CLIProxy alloc] initWithOptions:options inputFileDescriptor:inputFd outputFileDescriptor:outputFd errorFileDescriptor:errorFd connection:connection]];
				});
			}
			else
			{
				for(int fd : fds)
					close(fd);
				close(connection);
			}
		});

		if(!didListen)
		{
			os_log_error(OS_LOG_DEFAULT, "Unable to setup dialog server at %{public}s: %{darwin.errno}d", socketPath.c_str(), errno);
		}
		else if(NSString* path = [[NSBundle bundleForClass:[self class]] pathForResource:@"tm_dialog2" ofType:nil])
		{
			setenv("DIALOG", path.fileSystemRepresentation, 1);
			setenv(kDialogSocketEnvironmentVariable.UTF8String, socketPath.c_str(), 1);
		}
	}
	return self;
}

- (void)dispatch:(CLIProxy*)interface
{
	NSString* command = [interface numberOfArguments] <= 1 ? @"help" : [interface argumentAtIndex:1];
	if([command hasPrefix:@"-"])
		command = @"x-dialog-1"; // Options used by the Dialog 1 tool, e.g. ‘-a’ to load an asynchronous window

	if(id target = [TMDCommand objectForCommand:command])
			[target performSelector:@selector(handleCommand:) withObject:interface];
	else	[interface writeStringToError:@"unknown command, try help.\n"];
}
@end

/*
echo '{ menuItems = ({title = 'foo';});}' | "$DIALOG" menu
*/

#include <CommitWindow/CommitWindow.h>
#include <ipc/ipc.h>
#include <oak/oak.h>

static double const AppVersion = 1.2;

int main (int argc, char* argv[])
{
	if(argc == 2 && (strcmp(argv[1], "-v") == 0 || strcmp(argv[1], "--version") == 0))
	{
		fprintf(stderr, "%1$s %2$.1f (" __DATE__ ")\n", getprogname(), AppVersion);
		return EX_OK;
	}

	char const* appIdentifier = getenv("TM_APP_IDENTIFIER");
	char const* appPid        = getenv("TM_PID");
	if(!appIdentifier || !appPid)
	{
		fprintf(stderr, "%s: TM_APP_IDENTIFIER and TM_PID must be set. Run this tool from a TextMate command.\n", getprogname());
		return EX_UNAVAILABLE;
	}

	std::string const socketPath = ipc::socket_path(OakCommitWindowSocketName(appIdentifier, appPid));
	int connection = ipc::connect(socketPath);
	if(connection == -1)
	{
		fprintf(stderr, "%s: failed connecting to ‘%s’: %s\n", getprogname(), socketPath.c_str(), strerror(errno));
		return EX_UNAVAILABLE;
	}

	@autoreleasepool {
		NSMutableArray* args = [NSMutableArray array];
		for(size_t i = 0; i < argc; ++i)
			[args addObject:@(argv[i])];

		NSData* request = [NSPropertyListSerialization dataWithPropertyList:@{
			kOakCommitWindowArguments:   args,
			kOakCommitWindowEnvironment: NSProcessInfo.processInfo.environment,
		} format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];

		std::string message;
		if(!ipc::send(connection, std::string((char const*)request.bytes, request.length)) || !ipc::receive(connection, message))
		{
			fprintf(stderr, "%s: no reply from TextMate\n", getprogname());
			return EX_UNAVAILABLE;
		}

		NSDictionary* reply = [NSPropertyListSerialization propertyListWithData:[NSData dataWithBytes:message.data() length:message.size()] options:NSPropertyListImmutable format:nil error:nil];
		if(![reply isKindOfClass:[NSDictionary class]])
		{
			fprintf(stderr, "%s: malformed reply from TextMate\n", getprogname());
			return EX_PROTOCOL;
		}

		if(NSString* err = reply[kOakCommitWindowStandardError])
			fprintf(stderr, "%s", err.UTF8String);

		if(NSString* out = reply[kOakCommitWindowStandardOutput])
		{
			fprintf(stdout, "%s", out.UTF8String);
			if([reply[kOakCommitWindowContinue] boolValue])
				fprintf(stdout, "TM_SCM_COMMIT_CONTINUE=1\n");
		}

		return [reply[kOakCommitWindowReturnCode] intValue];
	}
}

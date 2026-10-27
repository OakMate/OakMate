//
//  client.mm
//  Created by Allan Odgaard on 2007-09-22.
//

#import "Dialog2.h"
#import <ipc/ipc.h>

static double const AppVersion = 2.1;

static void pipe_or_exit (int fds[2])
{
	if(pipe(fds) == -1)
	{
		perror("tm_dialog2: pipe");
		exit(EX_OSERR);
	}
	fcntl(fds[0], F_SETFD, FD_CLOEXEC);
	fcntl(fds[1], F_SETFD, FD_CLOEXEC);
}

int main (int argc, char const* argv[])
{
	if(argc == 2 && strcmp(argv[1], "--version") == 0)
	{
		fprintf(stderr, "%1$s %2$.1f (" __DATE__ ")\n", getprogname(), AppVersion);
		return EX_OK;
	}

	char const* socketPath = getenv(kDialogSocketEnvironmentVariable.UTF8String);
	if(!socketPath)
	{
		fprintf(stderr, "%s: %s is not set. Run this tool from a TextMate command.\n", getprogname(), kDialogSocketEnvironmentVariable.UTF8String);
		return EX_UNAVAILABLE;
	}

	int connection = ipc::connect(socketPath);
	if(connection == -1)
	{
		fprintf(stderr, "%s: error reaching TextMate: %s\n", getprogname(), strerror(errno));
		return EX_UNAVAILABLE;
	}

	@autoreleasepool {
		NSMutableArray* args = [NSMutableArray array];
		for(size_t i = 0; i < argc; ++i)
			[args addObject:@(argv[i])];

		char* cwd = getcwd(nullptr, 0);
		NSData* data = [NSPropertyListSerialization dataWithPropertyList:@{
			kDialogArgumentsKey:        args,
			kDialogEnvironmentKey:      NSProcessInfo.processInfo.environment,
			kDialogWorkingDirectoryKey: cwd ? @(cwd) : @"/",
		} format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
		free(cwd);

		int input[2], output[2], error[2];
		pipe_or_exit(input);
		pipe_or_exit(output);
		pipe_or_exit(error);

		if(!ipc::send(connection, std::string((char const*)data.bytes, data.length), { input[0], output[1], error[1] }))
		{
			fprintf(stderr, "%s: error sending request to TextMate: %s\n", getprogname(), strerror(errno));
			return EX_UNAVAILABLE;
		}

		close(input[0]);
		close(output[1]);
		close(error[1]);

		// Relay our input until TextMate closes its end of the output pipes
		std::map<int, int> fdMap = { { output[0], STDOUT_FILENO }, { error[0], STDERR_FILENO } };
		if(isatty(STDIN_FILENO))
				close(input[1]);
		else	fdMap.emplace(STDIN_FILENO, input[1]);

		signal(SIGPIPE, SIG_IGN);
		while(fdMap.size() > 1 || (fdMap.size() == 1 && fdMap.find(STDIN_FILENO) == fdMap.end()))
		{
			fd_set readfds;
			FD_ZERO(&readfds);

			int fdCount = 0;
			for(auto const& pair : fdMap)
			{
				FD_SET(pair.first, &readfds);
				fdCount = std::max(fdCount, pair.first + 1);
			}

			if(select(fdCount, &readfds, nullptr, nullptr, nullptr) == -1)
			{
				if(errno == EINTR)
					continue;
				perror("tm_dialog2: select");
				break;
			}

			std::vector<int> toRemove;
			for(auto const& pair : fdMap)
			{
				if(FD_ISSET(pair.first, &readfds))
				{
					char buf[4096];
					ssize_t len = read(pair.first, buf, sizeof(buf));
					if(len <= 0 || write(pair.second, buf, len) != len)
						toRemove.push_back(pair.first);
				}
			}

			for(int fd : toRemove)
			{
				if(fd == STDIN_FILENO)
					close(input[1]);
				fdMap.erase(fd);
			}
		}

		std::string exitStatus;
		if(ipc::receive(connection, exitStatus))
			return atoi(exitStatus.c_str());
	}
	return EX_OK;
}

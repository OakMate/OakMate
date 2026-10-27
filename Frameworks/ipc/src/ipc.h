#ifndef IPC_H_4XQ2M7RD
#define IPC_H_4XQ2M7RD

#include <oak/misc.h>

// Local communication between TextMate and its command line tools.
//
// A message is a length-prefixed blob sent over a Unix domain socket in the
// user’s private temporary folder. File descriptors can be sent along with a
// message, which lets a tool hand its pipes to TextMate. Only processes owned
// by the same user can connect.

namespace ipc
{
	// Path to a socket named ‘name’ in the user’s private temporary folder.
	std::string socket_path (std::string const& name);

	// Calls ‘handler’ on a background queue for each message received by a
	// connection to ‘path’. The handler owns the connection and the received
	// descriptors and must close them. The socket is removed when the process
	// exits. No dispatch_queue_t parameter: it mangles differently in C++ and
	// Objective-C++.
	bool listen (std::string const& path, void(^handler)(int connection, std::string const& message, std::vector<int> const& fds));

	// Returns a connected socket or -1 (errno is set).
	int connect (std::string const& path);

	bool send (int socket, std::string const& message, std::vector<int> const& fds = { });
	bool receive (int socket, std::string& message, std::vector<int>* fds = nullptr);

} /* ipc */

#endif /* end of include guard: IPC_H_4XQ2M7RD */

#include "ipc.h"
#include <sys/socket.h>
#include <sys/un.h>

static size_t const kMaxMessageSize = 64 << 20;
static size_t const kMaxDescriptors = 8;

namespace
{
	std::mutex SocketPathsMutex;
	std::vector<std::string> SocketPaths;

	void remove_sockets ()
	{
		std::lock_guard<std::mutex> lock(SocketPathsMutex);
		for(auto const& path : SocketPaths)
			unlink(path.c_str());
	}

	void remove_socket_at_exit (std::string const& path)
	{
		static std::once_flag onceFlag;
		std::call_once(onceFlag, []{ atexit(&remove_sockets); });

		std::lock_guard<std::mutex> lock(SocketPathsMutex);
		SocketPaths.push_back(path);
	}

	bool make_address (std::string const& path, sockaddr_un& addr)
	{
		addr = { .sun_family = AF_UNIX };
		if(path.size() >= sizeof(addr.sun_path))
		{
			errno = ENAMETOOLONG;
			return false;
		}
		strlcpy(addr.sun_path, path.c_str(), sizeof(addr.sun_path));
		return true;
	}

	bool write_all (int fd, char const* bytes, size_t len)
	{
		while(len)
		{
			ssize_t written = write(fd, bytes, len);
			if(written == -1 && errno == EINTR)
				continue;
			if(written <= 0)
				return false;
			bytes += written;
			len   -= written;
		}
		return true;
	}

	bool read_all (int fd, char* bytes, size_t len)
	{
		while(len)
		{
			ssize_t didRead = read(fd, bytes, len);
			if(didRead == -1 && errno == EINTR)
				continue;
			if(didRead <= 0)
				return false;
			bytes += didRead;
			len   -= didRead;
		}
		return true;
	}

	void close_all (std::vector<int> const& fds)
	{
		for(int fd : fds)
			close(fd);
	}
}

namespace ipc
{
	std::string socket_path (std::string const& name)
	{
		char buf[PATH_MAX];
		size_t len = confstr(_CS_DARWIN_USER_TEMP_DIR, buf, sizeof(buf));
		std::string dir = len && len <= sizeof(buf) ? buf : "/tmp/";
		if(dir.back() != '/')
			dir += '/';
		return dir + name;
	}

	bool listen (std::string const& path, void(^handler)(int connection, std::string const& message, std::vector<int> const& fds))
	{
		sockaddr_un addr;
		if(!make_address(path, addr))
			return false;

		int fd = socket(AF_UNIX, SOCK_STREAM, 0);
		if(fd == -1)
			return false;

		fcntl(fd, F_SETFD, FD_CLOEXEC);
		fcntl(fd, F_SETFL, O_NONBLOCK);

		unlink(path.c_str());
		mode_t oldMask = umask(S_IRWXG|S_IRWXO);
		bool didBind = bind(fd, (sockaddr*)&addr, sizeof(addr)) == 0;
		umask(oldMask);

		if(!didBind || ::listen(fd, SOMAXCONN) == -1)
		{
			int err = errno;
			close(fd);
			errno = err;
			return false;
		}

		remove_socket_at_exit(path);

		dispatch_source_t source = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, fd, 0, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0));
		dispatch_source_set_event_handler(source, ^{
			int connection;
			while((connection = accept(fd, nullptr, nullptr)) != -1)
			{
				uid_t uid; gid_t gid;
				if(getpeereid(connection, &uid, &gid) == -1 || uid != getuid())
				{
					close(connection);
					continue;
				}

				fcntl(connection, F_SETFD, FD_CLOEXEC);
				fcntl(connection, F_SETFL, fcntl(connection, F_GETFL) & ~O_NONBLOCK);

				int noSigPipe = 1;
				setsockopt(connection, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, sizeof(noSigPipe));

				timeval timeout = { .tv_sec = 30 };
				setsockopt(connection, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));

				dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
					std::string message;
					std::vector<int> fds;
					if(receive(connection, message, &fds))
					{
						timeval noTimeout = { };
						setsockopt(connection, SOL_SOCKET, SO_RCVTIMEO, &noTimeout, sizeof(noTimeout));

						handler(connection, message, fds);
					}
					else
					{
						close_all(fds);
						close(connection);
					}
				});
			}
		});
		dispatch_resume(source);

		return true;
	}

	int connect (std::string const& path)
	{
		sockaddr_un addr;
		if(!make_address(path, addr))
			return -1;

		int fd = socket(AF_UNIX, SOCK_STREAM, 0);
		if(fd == -1)
			return -1;

		fcntl(fd, F_SETFD, FD_CLOEXEC);

		int noSigPipe = 1;
		setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, sizeof(noSigPipe));

		if(::connect(fd, (sockaddr*)&addr, sizeof(addr)) == -1)
		{
			int err = errno;
			close(fd);
			errno = err;
			return -1;
		}
		return fd;
	}

	bool send (int socket, std::string const& message, std::vector<int> const& fds)
	{
		if(message.size() > kMaxMessageSize || fds.size() > kMaxDescriptors)
		{
			errno = EMSGSIZE;
			return false;
		}

		uint32_t len = message.size();
		iovec iov = { .iov_base = &len, .iov_len = sizeof(len) };

		char control[CMSG_SPACE(kMaxDescriptors * sizeof(int))] = { };
		msghdr msg = { .msg_iov = &iov, .msg_iovlen = 1 };
		if(!fds.empty())
		{
			msg.msg_control    = control;
			msg.msg_controllen = CMSG_SPACE(fds.size() * sizeof(int));

			cmsghdr* cmsg = CMSG_FIRSTHDR(&msg);
			cmsg->cmsg_level = SOL_SOCKET;
			cmsg->cmsg_type  = SCM_RIGHTS;
			cmsg->cmsg_len   = CMSG_LEN(fds.size() * sizeof(int));
			memcpy(CMSG_DATA(cmsg), fds.data(), fds.size() * sizeof(int));
		}

		ssize_t sent;
		while((sent = sendmsg(socket, &msg, 0)) == -1 && errno == EINTR)
			;
		if(sent == -1)
			return false;
		if(sent < sizeof(len) && !write_all(socket, (char const*)&len + sent, sizeof(len) - sent))
			return false;

		return write_all(socket, message.data(), message.size());
	}

	bool receive (int socket, std::string& message, std::vector<int>* fds)
	{
		uint32_t len = 0;
		iovec iov = { .iov_base = &len, .iov_len = sizeof(len) };

		char control[CMSG_SPACE(kMaxDescriptors * sizeof(int))] = { };
		msghdr msg = { .msg_iov = &iov, .msg_iovlen = 1, .msg_control = control, .msg_controllen = sizeof(control) };

		ssize_t received;
		while((received = recvmsg(socket, &msg, MSG_WAITALL)) == -1 && errno == EINTR)
			;

		std::vector<int> receivedFds;
		for(cmsghdr* cmsg = CMSG_FIRSTHDR(&msg); cmsg; cmsg = CMSG_NXTHDR(&msg, cmsg))
		{
			if(cmsg->cmsg_level == SOL_SOCKET && cmsg->cmsg_type == SCM_RIGHTS)
			{
				size_t count = (cmsg->cmsg_len - CMSG_LEN(0)) / sizeof(int);
				int const* first = (int const*)CMSG_DATA(cmsg);
				receivedFds.insert(receivedFds.end(), first, first + count);
			}
		}

		for(int fd : receivedFds)
			fcntl(fd, F_SETFD, FD_CLOEXEC);

		bool ok = received == sizeof(len) && !(msg.msg_flags & MSG_CTRUNC) && len <= kMaxMessageSize;
		if(ok)
		{
			message.resize(len);
			ok = read_all(socket, message.data(), len);
		}

		if(ok && fds)
			fds->swap(receivedFds);
		else
			close_all(receivedFds);

		return ok;
	}

} /* ipc */

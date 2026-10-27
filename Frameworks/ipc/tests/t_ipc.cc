#include <ipc/ipc.h>
#include <sys/socket.h>

void test_send_receive ()
{
	int sockets[2];
	OAK_ASSERT_EQ(socketpair(AF_UNIX, SOCK_STREAM, 0, sockets), 0);

	OAK_ASSERT(ipc::send(sockets[0], "hello"));
	OAK_ASSERT(ipc::send(sockets[0], ""));
	std::thread writer([&]{
		ipc::send(sockets[0], std::string(1 << 20, 'x')); // Larger than the socket buffer
		close(sockets[0]);
	});

	std::string message;
	OAK_ASSERT(ipc::receive(sockets[1], message));
	OAK_ASSERT_EQ(message, "hello");
	OAK_ASSERT(ipc::receive(sockets[1], message));
	OAK_ASSERT_EQ(message, "");

	OAK_ASSERT(ipc::receive(sockets[1], message));
	OAK_ASSERT_EQ(message.size(), 1 << 20);
	writer.join();
	OAK_ASSERT(!ipc::receive(sockets[1], message));

	close(sockets[1]);
}

void test_send_descriptors ()
{
	int sockets[2], fds[2];
	OAK_ASSERT_EQ(socketpair(AF_UNIX, SOCK_STREAM, 0, sockets), 0);
	OAK_ASSERT_EQ(pipe(fds), 0);

	OAK_ASSERT(ipc::send(sockets[0], "pipe", { fds[1] }));
	close(fds[1]);

	std::string message;
	std::vector<int> received;
	OAK_ASSERT(ipc::receive(sockets[1], message, &received));
	OAK_ASSERT_EQ(message, "pipe");
	OAK_ASSERT_EQ(received.size(), 1);

	OAK_ASSERT_EQ(write(received[0], "data", 4), 4);
	close(received[0]);

	char buf[16];
	OAK_ASSERT_EQ(read(fds[0], buf, sizeof(buf)), 4);
	OAK_ASSERT_EQ(read(fds[0], buf, sizeof(buf)), 0); // All write ends are closed
	close(fds[0]);

	close(sockets[0]);
	close(sockets[1]);
}

void test_listen ()
{
	std::string const path = ipc::socket_path("test_ipc." + std::to_string(getpid()));
	OAK_ASSERT(ipc::listen(path, ^(int connection, std::string const& message, std::vector<int> const& fds){
		ipc::send(connection, "reply to " + message);
		close(connection);
	}));

	struct stat sbuf;
	OAK_ASSERT_EQ(stat(path.c_str(), &sbuf), 0);
	OAK_ASSERT_EQ(sbuf.st_mode & (S_IRWXG|S_IRWXO), 0);

	int fd = ipc::connect(path);
	OAK_ASSERT_NE(fd, -1);
	OAK_ASSERT(ipc::send(fd, "request"));

	std::string reply;
	OAK_ASSERT(ipc::receive(fd, reply));
	OAK_ASSERT_EQ(reply, "reply to request");
	OAK_ASSERT(!ipc::receive(fd, reply));
	close(fd);

	OAK_ASSERT_EQ(ipc::connect(ipc::socket_path("test_ipc.missing")), -1);
}

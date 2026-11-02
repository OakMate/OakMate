#include <oak/oak.h>
#include <text/format.h>
#include <text/types.h>
#include <document/OakDocument.h>
#include <document/OakDocumentController.h>
#include <io/path.h>
#include <io/socket.h>
#include <ipc/ipc.h>
#include <ns/ns.h>
#include <OakAppKit/IOAlertPanel.h>

/*
	Protocol used by mate (over a Unix domain socket in the user’s private temporary folder) and rmate (over TCP).

	The server sends a greeting line. The client then sends records, each a command followed by ‘«key»: «value»’ lines and an empty line, and ends the request with a line containing a single period. In values a newline is written as \n and a backslash as \\.

		open
		path: «path»                                         (local only)
		uuid: «uuid»                                         (local only)
		real-path: «path»
		token: «string»
		display-name: «string»
		selection: «line»[:«column»][-«line»[:«column»]]
		file-type: «scope»
		project-uuid: «uuid»
		add-to-recents: «boolean»
		re-activate: «boolean»
		wait: «boolean»
		data-on-save: «boolean»
		data-on-close: «boolean»
		data: «integer»
		«integer bytes of content, possibly repeated»

		set-mark | clear-mark                                (local only)
		mark: «type»[:«content»]
		line: «line»
		path: «path» | uuid: «uuid»

	While a document opened with wait, data-on-save, or data-on-close is open the connection stays open, and the server sends ‘save’ and ‘close’ records with the token and, when asked for, the document’s content as data.

	Connections over TCP are not authenticated: any process that can reach the port can make requests. They are therefore limited to opening the content they send, never local files or open documents.
*/

static char const* const kMateSocketName = "com.isztld.oakmate.mate.sock"; // Must match Applications/mate

static size_t const   kMaxLineLength = 64 << 10;
static size_t const   kMaxRecords    = 10000;
static uint64_t const kMaxDataSize   = 1ULL << 30; // Per connection
static timeval const  kSendTimeout   = { .tv_sec = 10 };

namespace
{
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

	bool write_all (int fd, std::string const& str)
	{
		return write_all(fd, str.data(), str.size());
	}

	std::string unescape (std::string const& str)
	{
		std::string res;
		for(size_t i = 0; i < str.size(); ++i)
		{
			if(str[i] == '\\' && i+1 < str.size())
			{
				char const ch = str[++i];
				res += ch == 'n' ? '\n' : (ch == 'r' ? '\r' : ch);
			}
			else
			{
				res += str[i];
			}
		}
		return res;
	}

	bool parse_size (std::string const& str, uint64_t& res)
	{
		if(str.empty() || str.size() > 12 || str.find_first_not_of("0123456789") != std::string::npos)
			return false;
		res = strtoull(str.c_str(), nullptr, 10);
		return true;
	}

	std::string greeting ()
	{
		char host[256] = "localhost";
		gethostname(host, sizeof(host));
		host[sizeof(host)-1] = '\0';
		return text::format("220 %s RMATE OakMate\n", host);
	}

	// Calls ‘handler’ on the main queue whenever ‘socket’ is readable, until it returns false or the returned source is canceled. The socket stays open until then.
	dispatch_source_t observe (socket_t const& socket, std::function<bool()> const& handler)
	{
		dispatch_source_t source = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, socket, 0, dispatch_get_main_queue());
		__block dispatch_source_t blockSource = source;
		__block std::function<bool()> blockHandler = handler;
		dispatch_source_set_event_handler(source, ^{
			if(blockSource && !blockHandler())
			{
				dispatch_source_cancel(blockSource);
				blockSource = nil;
			}
		});
		socket_t keepOpen = socket; // Blocks capture C++ references by reference, so copy it to keep the socket open until the source is canceled
		dispatch_source_set_cancel_handler(source, ^{
			[[maybe_unused]] socket_t const& socket = keepOpen;
		});
		dispatch_resume(source);
		return source;
	}

	// ===============
	// = Document IO =
	// ===============

	struct temp_file_t
	{
		temp_file_t ()
		{
			std::string str = path::join(path::temp(), "rmate_buffer.XXXXXX");
			if((_fd = mkstemp(&str[0])) != -1)
			{
				fcntl(_fd, F_SETFD, FD_CLOEXEC);
				_path = str;
			}
		}

		temp_file_t (temp_file_t const&) = delete;
		temp_file_t& operator= (temp_file_t const&) = delete;

		~temp_file_t ()
		{
			close_fd();
			if(_path != NULL_STR)
				unlink(_path.c_str());
		}

		explicit operator bool () const                { return _fd != -1; }
		std::string const& path () const               { return _path; }
		bool append (char const* bytes, size_t len)    { return _fd != -1 && write_all(_fd, bytes, len); }
		void close_fd ()                               { if(_fd != -1) close(_fd); _fd = -1; }

	private:
		std::string _path = NULL_STR;
		int _fd = -1;
	};

	struct record_t
	{
		record_t (std::string const& command) : command(command) { }

		bool has (std::string const& key) const        { return arguments.find(key) != arguments.end(); }
		std::string get (std::string const& key) const { auto it = arguments.find(key); return it != arguments.end() ? it->second : NULL_STR; }
		bool flag (std::string const& key) const       { return get(key) == "yes"; }

		std::string command;
		std::map<std::string, std::string> arguments;
		std::shared_ptr<temp_file_t> data;
	};

	struct base_t
	{
		base_t (OakDocument* document)
		{
			_close_observer = [NSNotificationCenter.defaultCenter addObserverForName:OakDocumentWillCloseNotification object:document queue:nil usingBlock:^(NSNotification*){
				this->close_document(document);
				delete this;
			}];
			_save_observer = [NSNotificationCenter.defaultCenter addObserverForName:OakDocumentDidSaveNotification object:document queue:nil usingBlock:^(NSNotification*){
				this->save_document(document);
			}];
		}

		virtual ~base_t ()
		{
			[NSNotificationCenter.defaultCenter removeObserver:_save_observer];
			[NSNotificationCenter.defaultCenter removeObserver:_close_observer];
		}

		virtual void save_document (OakDocument* document)  { }
		virtual void close_document (OakDocument* document) { }

	private:
		id _save_observer;
		id _close_observer;
	};

	struct retain_temp_file_callback_t : base_t
	{
		retain_temp_file_callback_t (OakDocument* document, std::shared_ptr<temp_file_t> const& file) : base_t(document), file(file) { }
		std::shared_ptr<temp_file_t> file;
	};

	struct save_close_callback_t : base_t
	{
		save_close_callback_t (OakDocument* document, std::string const& path, socket_t const& socket, bool data_on_save, bool data_on_close, std::string const& token) : base_t(document), path(path), socket(socket), data_on_save(data_on_save), data_on_close(data_on_close), token(token)
		{
		}

		void save_document (OakDocument* document)
		{
			if(!send("save", data_on_save))
				os_log_error(OS_LOG_DEFAULT, "rmate: unable to report saving of ‘%{public}@’", document.displayName);
		}

		void close_document (OakDocument* document)
		{
			if(!send("close", data_on_close))
				os_log_error(OS_LOG_DEFAULT, "rmate: unable to report closing of ‘%{public}@’", document.displayName);
		}

	private:
		bool send (std::string const& command, bool includeData) const
		{
			bool res = write_all(socket, command + "\r\n");
			if(res && token != NULL_STR)
				res = write_all(socket, "token: " + token + "\r\n");
			if(res && includeData)
				res = write_data();
			return res && write_all(socket, "\r\n");
		}

		bool write_data () const
		{
			int fd = path == NULL_STR ? -1 : open(path.c_str(), O_RDONLY|O_CLOEXEC);
			if(fd == -1)
				return false;

			bool res = true;
			char buf[64 << 10];
			ssize_t len;
			while(res && (len = read(fd, buf, sizeof(buf))) != 0)
			{
				if(len == -1)
					res = errno == EINTR;
				else
					res = write_all(socket, text::format("data: %zd\r\n", len)) && write_all(socket, buf, len);
			}
			close(fd);
			return res;
		}

		std::string path;
		socket_t socket;
		bool data_on_save;
		bool data_on_close;
		std::string token;
	};

	struct reactivate_callback_t
	{
		reactivate_callback_t () : _shared_count(std::make_shared<size_t>(0))
		{
			_terminal = std::make_shared<NSRunningApplication*>([NSWorkspace.sharedWorkspace frontmostApplication]);

			auto terminal = _terminal;
			if([*terminal isEqual:NSRunningApplication.currentApplication])
			{
				// If we call ‘mate -w’ in quick succession there is a chance that we have not yet re-activated the terminal app when we are asked to open a new document. For this reason, we monitor the NSApplicationDidResignActiveNotification for 200 ms to see if the “real” frontmost application becomes active.

				__weak __block id token = [NSNotificationCenter.defaultCenter addObserverForName:NSApplicationDidResignActiveNotification object:NSApp queue:nil usingBlock:^(NSNotification*){
					[NSNotificationCenter.defaultCenter removeObserver:token];
					*terminal = [NSWorkspace.sharedWorkspace frontmostApplication];
				}];

				dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 5), dispatch_get_main_queue(), ^{
					[NSNotificationCenter.defaultCenter removeObserver:token];
				});
			}
		}

		void watch_document (OakDocument* document)
		{
			auto counter  = _shared_count;
			auto terminal = _terminal;

			++*counter;
			__weak __block id token = [NSNotificationCenter.defaultCenter addObserverForName:OakDocumentWillCloseNotification object:document queue:nil usingBlock:^(NSNotification*){
				if(--*counter == 0)
					[*terminal activateFromApplication:NSRunningApplication.currentApplication options:0];
				[NSNotificationCenter.defaultCenter removeObserver:token];
			}];
		}

	private:
		std::shared_ptr<size_t> _shared_count;
		std::shared_ptr<NSRunningApplication*> _terminal;
	};

	NSUUID* to_uuid (std::string const& str)
	{
		return str == NULL_STR ? nil : [[NSUUID alloc] initWithUUIDString:to_ns(str)];
	}

	// ==============
	// = Connection =
	// ==============

	struct connection_t
	{
		connection_t (socket_t const& socket, bool isLocal) : _socket(socket), _is_local(isLocal) { }

		// Called when the socket is readable. Returns false when no more data should be read.
		bool receive ()
		{
			char buf[64 << 10];
			ssize_t len = read(_socket, buf, sizeof(buf));
			if(len == -1 && (errno == EINTR || errno == EAGAIN))
				return true;
			if(len <= 0)
				return false;

			if(!consume(buf, len))
			{
				os_log_error(OS_LOG_DEFAULT, "rmate: closing connection after invalid request");
				return false;
			}

			if(_state != kDone)
				return true;

			if(_records.empty() || _records.front().command == "open") // No command brings OakMate to the front
				open_documents();
			else if(_is_local)
				handle_marks();
			return false;
		}

	private:
		bool consume (char const* bytes, size_t len)
		{
			_buffer.append(bytes, len);

			size_t pos = 0;
			while(_state != kDone && pos < _buffer.size())
			{
				if(_state == kData)
				{
					size_t const n = std::min<uint64_t>(_bytes_left, _buffer.size() - pos);
					if(!_records.back().data->append(_buffer.data() + pos, n))
						return false;
					pos         += n;
					_bytes_left -= n;
					if(_bytes_left == 0)
						_state = kArguments;
					continue;
				}

				size_t const eol = _buffer.find('\n', pos);
				if(eol == std::string::npos)
				{
					if(_buffer.size() - pos > kMaxLineLength)
						return false;
					break;
				}

				std::string line = _buffer.substr(pos, eol - pos);
				pos = eol + 1;
				if(!line.empty() && line.back() == '\r')
					line.pop_back();
				if(!parse_line(line))
					return false;
			}

			_buffer.erase(0, pos);
			return true;
		}

		bool parse_line (std::string const& line)
		{
			if(line.empty())
			{
				_state = kCommand;
			}
			else if(_state == kCommand)
			{
				if(line == "." || strcasecmp(line.c_str(), "quit") == 0)
				{
					_state = kDone;
				}
				else
				{
					if(_records.size() == kMaxRecords || line.find(" HTTP/") != std::string::npos) // Web pages can make browsers send HTTP requests to the rmate port
						return false;
					_records.emplace_back(line);
					_state = kArguments;
				}
			}
			else
			{
				std::string::size_type n = line.find(':');
				if(n == std::string::npos)
					return true;

				std::string const key   = line.substr(0, n);
				std::string const value = line.substr(n + (line.compare(n, 2, ": ") == 0 ? 2 : 1));

				if(key == "data")
				{
					uint64_t size;
					if(!parse_size(value, size) || size > kMaxDataSize - _data_size)
						return false;

					record_t& record = _records.back();
					if(!record.data && !*(record.data = std::make_shared<temp_file_t>()))
						return false;

					_data_size  += size;
					_bytes_left  = size;
					if(size)
						_state = kData;
				}
				else if(!value.empty())
				{
					_records.back().arguments.emplace(key, unescape(value));
				}
			}
			return true;
		}

		void open_documents ()
		{
			reactivate_callback_t reactivateCallback;

			NSMutableArray<OakDocument*>* documents = [NSMutableArray array];
			for(record_t& record : _records)
			{
				if(record.command != "open")
					continue;

				if(!_is_local && (record.has("path") || record.has("uuid")))
				{
					os_log_error(OS_LOG_DEFAULT, "rmate: ignoring request from network client to open a local file or document");
					continue;
				}

				if(record.data)
					record.data->close_fd();

				bool const wait        = record.flag("wait");
				bool const dataOnSave  = record.flag("data-on-save");
				bool const dataOnClose = record.flag("data-on-close");
				std::string const fileType = record.get("file-type");

				OakDocument* doc;
				if(record.has("path"))
				{
					std::string const path = record.get("path");
					if(!path::is_absolute(path))
						continue;

					if(path::is_directory(path))
					{
						[OakDocumentController.sharedInstance showFileBrowserAtPath:to_ns(path)];
						continue;
					}
					doc = [OakDocumentController.sharedInstance documentWithPath:to_ns(path)];
				}
				else if(record.has("uuid"))
				{
					NSUUID* uuid = to_uuid(record.get("uuid"));
					if(!uuid || !(doc = [OakDocumentController.sharedInstance findDocumentWithIdentifier:uuid]))
						continue;
				}
				else if(record.data)
				{
					if(dataOnSave || dataOnClose)
					{
						doc = [OakDocumentController.sharedInstance documentWithPath:to_ns(record.data->path())];
						doc.recentTrackingDisabled = YES;
					}
					else
					{
						doc = [OakDocument documentWithData:[NSData dataWithContentsOfFile:to_ns(record.data->path())] fileType:(fileType == NULL_STR ? nil : to_ns(fileType)) customName:nil];
					}
				}
				else
				{
					doc = [OakDocumentController.sharedInstance untitledDocument];
				}

				if(fileType != NULL_STR)
					doc.fileType = to_ns(fileType);

				if(record.has("real-path"))
					doc.virtualPath = to_ns(record.get("real-path"));

				if(record.has("display-name"))
					doc.customName = to_ns(record.get("display-name"));

				if(record.has("selection"))
					doc.selection = to_ns(record.get("selection"));

				if(!record.flag("add-to-recents"))
					doc.recentTrackingDisabled = YES;

				if(wait || dataOnSave || dataOnClose)
					new save_close_callback_t(doc, to_s(doc.path), _socket, dataOnSave, dataOnClose, record.get("token"));

				if(record.data && (dataOnSave || dataOnClose))
					new retain_temp_file_callback_t(doc, record.data);

				if(record.flag("re-activate"))
					reactivateCallback.watch_document(doc);

				if(NSUUID* projectUUID = to_uuid(record.get("project-uuid")))
						[OakDocumentController.sharedInstance showDocument:doc inProject:projectUUID bringToFront:YES];
				else	[documents addObject:doc];
			}

			if(documents.count)
					[OakDocumentController.sharedInstance showDocuments:documents];
			else	[NSApp activateIgnoringOtherApps:YES];
		}

		void handle_marks ()
		{
			for(record_t const& record : _records)
			{
				if(record.command != "clear-mark" && record.command != "set-mark")
					continue;

				OakDocument* doc;
				if(record.has("uuid"))
				{
					NSUUID* uuid = to_uuid(record.get("uuid"));
					if(!uuid || !(doc = [OakDocumentController.sharedInstance findDocumentWithIdentifier:uuid]))
						continue;
				}
				else if(record.has("path"))
				{
					if(!path::is_absolute(record.get("path")))
						continue;
					doc = [OakDocumentController.sharedInstance documentWithPath:to_ns(record.get("path"))];
				}

				std::string const mark = record.get("mark");
				if(mark == NULL_STR)
					continue;

				text::pos_t const line = record.has("line") ? text::pos_t(record.get("line")) : text::pos_t::undefined;
				if(record.command == "clear-mark")
				{
					if(doc)
							[doc removeMarkOfType:to_ns(mark) atPosition:line];
					else	[OakDocument removeAllMarksOfType:to_ns(mark)];
				}
				else if(doc)
				{
					std::string::size_type n = mark.find(':');
					[doc setMarkOfType:to_ns(mark.substr(0, n)) atPosition:line content:(n == std::string::npos ? nil : to_ns(mark.substr(n+1)))];
				}
			}
		}

		socket_t _socket;
		bool _is_local;

		enum { kCommand, kArguments, kData, kDone } _state = kCommand;
		std::string _buffer;
		std::vector<record_t> _records;
		uint64_t _bytes_left = 0;
		uint64_t _data_size  = 0;
	};

	// ===========
	// = Servers =
	// ===========

	void accept_connection (socket_t const& socket, bool isLocal)
	{
		if(isLocal && !ipc::is_same_user(socket))
			return;

		fcntl(socket, F_SETFL, fcntl(socket, F_GETFL) & ~O_NONBLOCK);

		int const on = 1;
		setsockopt(socket, SOL_SOCKET, SO_NOSIGPIPE, &on, sizeof(on));
		setsockopt(socket, SOL_SOCKET, SO_SNDTIMEO, &kSendTimeout, sizeof(kSendTimeout)); // Writes happen on the main thread

		if(!write_all(socket, greeting()))
			return;

		auto connection = std::make_shared<connection_t>(socket, isLocal);
		observe(socket, [connection]{ return connection->receive(); });
	}

	struct server_t
	{
		server_t (socket_t const& listener, bool isLocal)
		{
			_source = observe(listener, [listener, isLocal]{
				int fd;
				while((fd = accept(listener, nullptr, nullptr)) != -1)
					accept_connection(socket_t(fd), isLocal);
				return true;
			});
		}

		~server_t ()
		{
			dispatch_source_cancel(_source);
		}

	private:
		dispatch_source_t _source;
	};

	struct mate_server_t
	{
		mate_server_t ()
		{
			std::string const path = ipc::socket_path(kMateSocketName);
			socket_t listener(ipc::bind(path));
			if(listener)
					_server = std::make_unique<server_t>(listener, true);
			else	OakRunIOAlertPanel("Unable to create the socket used by mate:\n%s", path.c_str());
		}

	private:
		std::unique_ptr<server_t> _server;
	};

	struct rmate_server_t
	{
		rmate_server_t (uint16_t port, bool listenForRemoteClients) : _port(port), _listen_for_remote_clients(listenForRemoteClients)
		{
			socket_t listener(socket(PF_INET6, SOCK_STREAM, 0));
			if(!listener)
				return;

			int const on = 1;
			setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &on, sizeof(on));
			fcntl(listener, F_SETFL, O_NONBLOCK);

			sockaddr_in6 addr = { .sin6_len = sizeof(sockaddr_in6), .sin6_family = AF_INET6, .sin6_port = htons(port) };
			addr.sin6_addr = listenForRemoteClients ? in6addr_any : in6addr_loopback;
			if(bind(listener, (sockaddr*)&addr, sizeof(addr)) == -1 || listen(listener, SOMAXCONN) == -1)
			{
				os_log_error(OS_LOG_DEFAULT, "rmate: unable to listen on port %d: %{public}s", port, strerror(errno));
				return;
			}

			_server = std::make_unique<server_t>(listener, false);
		}

		uint16_t port () const                  { return _port; }
		bool listen_for_remote_clients () const { return _listen_for_remote_clients; }

	private:
		uint16_t _port;
		bool _listen_for_remote_clients;
		std::unique_ptr<server_t> _server;
	};
}

void setup_rmate_server (bool enabled, uint16_t port, bool listenForRemoteClients)
{
	static mate_server_t mate_server;

	static std::unique_ptr<rmate_server_t> rmate_server;
	if(!enabled || !rmate_server || port != rmate_server->port() || listenForRemoteClients != rmate_server->listen_for_remote_clients())
	{
		rmate_server.reset();
		if(enabled)
			rmate_server = std::make_unique<rmate_server_t>(port, listenForRemoteClients);
	}
}

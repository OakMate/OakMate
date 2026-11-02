// mate opens files, folders, and its standard input in OakMate.
//
// It connects to the socket of the running OakMate, launching OakMate when needed, and sends a request in the protocol described in Applications/OakMate/src/RMateServer.mm. When waiting, it stays connected until OakMate reports that the documents are closed, writing the edited content of standard input to standard output.

#include <oak/oak.h>
#include <text/format.h>
#include <io/path.h>
#include <ipc/ipc.h>
#include <mach-o/dyld.h>
#include <getopt.h>
#include <pwd.h>
#include <optional>
#include <sstream>

static char const* const AppVersion        = "2.14";
static char const* const kBundleIdentifier = "com.isztld.oakmate";
static char const* const kMateSocketName   = "com.isztld.oakmate.mate.sock"; // Must match Applications/OakMate/src/RMateServer.mm
static size_t const      kMaxLineLength    = 64 << 10;

[[noreturn]] static void die (int code, char const* format, ...) __attribute__ ((format (printf, 2, 3)));

static void die (int code, char const* format, ...)
{
	va_list ap;
	va_start(ap, format);
	fprintf(stderr, "%s: ", getprogname());
	vfprintf(stderr, format, ap);
	fprintf(stderr, "\n");
	va_end(ap);
	exit(code);
}

static bool write_all (int fd, char const* bytes, size_t len)
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

static bool parse_number (char const* str, uint64_t max, uint64_t& res)
{
	if(!str || !*str || strspn(str, "0123456789") != strlen(str) || strlen(str) > 19)
		return false;
	res = strtoull(str, nullptr, 10);
	return res <= max;
}

// =============
// = Privileges =
// =============

// Under sudo, mate runs as the invoking user. OakMate runs in their session and asks them to authenticate when a file requires administrator privileges, so mate never needs root.
static void drop_sudo_privileges ()
{
	if(geteuid() != 0)
		return;

	uint64_t uid, gid;
	if(!parse_number(getenv("SUDO_UID"), UID_MAX, uid) || !parse_number(getenv("SUDO_GID"), GID_MAX, gid) || uid == 0)
		die(EX_NOPERM, "must be run by the user running OakMate, not as root");

	passwd* pw = getpwuid((uid_t)uid);
	if(!pw || initgroups(pw->pw_name, (int)gid) != 0 || setgid((gid_t)gid) != 0 || setuid((uid_t)uid) != 0 || setuid(0) == 0)
		die(EX_OSERR, "unable to drop root privileges");
}

// ===========
// = OakMate =
// ===========

// mate inside OakMate.app (Contents/MacOS/mate) uses that copy, so that a development build is not mistaken for the installed one.
static NSURL* containing_app ()
{
	char buf[PATH_MAX];
	uint32_t size = sizeof(buf);
	if(_NSGetExecutablePath(buf, &size) != 0)
		return nil;

	NSURL* url = [NSURL fileURLWithFileSystemRepresentation:buf isDirectory:NO relativeToURL:nil].URLByResolvingSymlinksInPath;
	NSURL* app = url.URLByDeletingLastPathComponent.URLByDeletingLastPathComponent.URLByDeletingLastPathComponent;
	return [[NSBundle bundleWithURL:app].bundleIdentifier isEqualToString:@(kBundleIdentifier)] ? app : nil;
}

static void launch_app (bool disableUntitled)
{
	NSURL* app = containing_app() ?: [NSWorkspace.sharedWorkspace URLForApplicationWithBundleIdentifier:@(kBundleIdentifier)];
	if(!app)
		die(EX_UNAVAILABLE, "can’t find OakMate.app");

	NSWorkspaceOpenConfiguration* config = [NSWorkspaceOpenConfiguration configuration];
	config.activates         = NO;
	config.addsToRecentItems = NO;
	if(disableUntitled)
		config.arguments = @[ @"-disableNewDocumentAtStartup", @"1" ];

	__block NSError* error;
	dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
	[NSWorkspace.sharedWorkspace openApplicationAtURL:app configuration:config completionHandler:^(NSRunningApplication* runningApp, NSError* err){
		error = err;
		dispatch_semaphore_signal(semaphore);
	}];
	dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);

	if(error)
		die(EX_UNAVAILABLE, "can’t launch OakMate.app: %s", error.localizedDescription.UTF8String);
}

static int connect_to_app (bool disableUntitled)
{
	std::string const socketPath = ipc::socket_path(kMateSocketName);

	int fd = ipc::connect(socketPath);
	if(fd == -1 && (errno == ENOENT || errno == ECONNREFUSED))
	{
		launch_app(disableUntitled);
		for(size_t i = 0; i < 100 && fd == -1; ++i) // Wait up to 10 seconds for OakMate to create the socket
		{
			usleep(100000);
			fd = ipc::connect(socketPath);
		}
	}

	if(fd == -1)
		die(EX_UNAVAILABLE, "unable to connect to OakMate: %s", strerror(errno));
	if(!ipc::is_same_user(fd))
		die(EX_NOPERM, "the OakMate socket belongs to another user");
	return fd;
}

// ============
// = Protocol =
// ============

static void send (int fd, std::string const& str)
{
	if(!write_all(fd, str.data(), str.size()))
		die(EX_IOERR, "lost connection to OakMate: %s", strerror(errno));
}

static std::string key_value (std::string const& key, std::string const& value)
{
	std::string res = key + ": ";
	for(char ch : value)
	{
		switch(ch)
		{
			case '\\': res += "\\\\"; break;
			case '\n': res += "\\n";  break;
			case '\r': res += "\\r";  break;
			default:   res += ch;     break;
		}
	}
	return res + "\r\n";
}

struct reader_t
{
	reader_t (int fd) : _fd(fd) { }

	// Returns false at the end of the connection
	bool read_line (std::string& line)
	{
		std::string::size_type eol;
		while((eol = _buffer.find('\n')) == std::string::npos)
		{
			if(_buffer.size() > kMaxLineLength)
				die(EX_PROTOCOL, "invalid reply from OakMate");
			if(!fill())
				return false;
		}

		line = _buffer.substr(0, eol);
		_buffer.erase(0, eol + 1);
		if(!line.empty() && line.back() == '\r')
			line.pop_back();
		return true;
	}

	// Copies ‘len’ bytes to ‘fd’ or discards them when ‘fd’ is -1. Returns false at the end of the connection.
	bool copy (uint64_t len, int fd)
	{
		while(len)
		{
			if(_buffer.empty() && !fill())
				return false;

			size_t const n = std::min<uint64_t>(len, _buffer.size());
			if(fd != -1 && !write_all(fd, _buffer.data(), n))
				die(EX_IOERR, "write: %s", strerror(errno));
			_buffer.erase(0, n);
			len -= n;
		}
		return true;
	}

private:
	bool fill ()
	{
		char buf[64 << 10];
		ssize_t len;
		while((len = read(_fd, buf, sizeof(buf))) == -1 && errno == EINTR)
			;
		if(len <= 0)
			return false;
		_buffer.append(buf, len);
		return true;
	}

	int _fd;
	std::string _buffer;
};

// Removes ANSI escape sequences from [first, last) in place and returns the new end. ‘state’ carries partial sequences over to the next call.
namespace
{
	enum class escape_state_t { kPlain, kEscape, kANSI };
}

static char* remove_ansi_escapes (char* first, char* last, escape_state_t& state)
{
	char* dst = first;
	for(char* it = first; it != last; ++it)
	{
		unsigned char const ch = *it;
		switch(state)
		{
			case escape_state_t::kPlain:  if(ch == '\e') state = escape_state_t::kEscape; else *dst++ = ch; break;
			case escape_state_t::kEscape: state = ch == '[' ? escape_state_t::kANSI : escape_state_t::kPlain;  break;
			case escape_state_t::kANSI:   if(0x40 <= ch && ch <= 0x7E) state = escape_state_t::kPlain;         break;
		}
	}
	return dst;
}

// ===========
// = Options =
// ===========

static void usage (FILE* io)
{
	std::string pad(8 - std::min(strlen(getprogname()), size_t(8)), ' ');

	fprintf(io,
		"%1$s %2$s\n"
		"Usage: %1$s [-awl<selection>t<filetype>m<name>p<project>rehv] [-u<identifier> | file ...]\n"
		"       %1$s [-c<mark>] -s<mark>:<value> -l<line> [-u<identifier> | file ...]\n"
		"       %1$s -c<mark> [-l<line>] [-u<identifier> | file ...]\n"
		"\n"
		"Options:\n"
		" -w, --[no-]wait                 Wait for file to be closed by OakMate.\n"
		" -a, --async                     Do not wait for file to be closed (same as --no-wait).\n"
		" -l, --line <selection>          Setup <selection> after loading file.\n"
		" -t, --type <filetype>           Treat file as having <filetype>.\n"
		" -m, --name <name>               The display name shown in OakMate.\n"
		" -p, --project <identifier>      Open file in the project with <identifier>.\n"
		" -r, --[no-]recent               Add file to Open Recent menu.\n"
		" -u, --uuid <identifier>         Reference already open document with\n"
		"                                 <identifier>.\n"
		" -e, --[no-]escapes              Set this to preserve ANSI escapes from stdin.\n"
		" -s, --set-mark <mark>[:<value>] Set a mark with optional <value> (requires --line).\n"
		" -c, --clear-mark <mark>         Clear a mark (clears all marks without --line).\n"
		" -h, --help                      Show this information.\n"
		" -v, --version                   Print version information.\n"
		"\n"
		"Options from the MATEFLAGS environment variable are read first.\n"
		"\n"
		"Files opened via %1$s are added to the recent menu unless\n"
		"the file starts with a period, --wait or --no-recent is\n"
		"specified, or the file is in the system’s temporary directory.\n"
		"\n"
		"By default %1$s will wait for files to be closed if the command name\n"
		"has a \"_wait\" suffix (e.g. via a symbolic link) or when used as a\n"
		"filter as in these examples:\n"
		"\n"
		"    ls *.tex|%1$s|sh%3$s-w implied\n"
		"    %1$s -|cat -n   %3$s-w implied (read from stdin)\n"
		"\n"
		"The -l/--line option requires a selection in the following format:\n"
		"\n"
		"    selection    = <range> ('&' <range>)*\n"
		"    range        = <pos> | <normal_range> | <column_range>\n"
		"    pos          = <line> (':' <column>)? ('+' <offset>)?\n"
		"    normal_range = <pos> '-' <pos>\n"
		"    column_range = <pos> 'x' <pos>\n"
		"    line         = [1-9][0-9]*\n"
		"    column       = [1-9][0-9]*\n"
		"    offset       = [1-9][0-9]*\n"
		"\n", getprogname(), AppVersion, pad.c_str()
	);
}

struct target_t
{
	enum kind_t { kPath, kDocument, kStdin } kind;
	std::string value;

	std::string reference () const { return key_value(kind == kDocument ? "uuid" : "path", value); }
};

struct options_t
{
	std::vector<std::string> lines, types, names, projects, setMarks, clearMarks;
	std::string uuid = NULL_STR;
	std::optional<bool> wait, addToRecent, keepEscapes;
};

static void append (char const* str, std::vector<std::string>& v)
{
	std::string const s = str;
	for(std::string::size_type from = 0; from < s.size(); )
	{
		std::string::size_type to = s.find(',', from);
		v.push_back(s.substr(from, to == std::string::npos ? std::string::npos : to - from));
		from = to == std::string::npos ? s.size() : to + 1;
	}
}

static bool is_uuid (std::string const& str)
{
	return [[NSUUID alloc] initWithUUIDString:@(str.c_str())] != nil;
}

// Parses the options in argv and returns the index of the first argument that is not an option. Exits for --help, --version, and invalid options.
static int parse_options (int argc, char* argv[], options_t& options)
{
	static option const longopts[] = {
		{ "async",      no_argument,       nullptr, 'a' },
		{ "clear-mark", required_argument, nullptr, 'c' },
		{ "change-dir", no_argument,       nullptr, 'd' }, // Accepted for compatibility, does nothing
		{ "escapes",    no_argument,       nullptr, 'e' },
		{ "no-escapes", no_argument,       nullptr, 'E' },
		{ "help",       no_argument,       nullptr, 'h' },
		{ "line",       required_argument, nullptr, 'l' },
		{ "name",       required_argument, nullptr, 'm' },
		{ "project",    required_argument, nullptr, 'p' },
		{ "recent",     no_argument,       nullptr, 'r' },
		{ "no-recent",  no_argument,       nullptr, 'R' },
		{ "set-mark",   required_argument, nullptr, 's' },
		{ "type",       required_argument, nullptr, 't' },
		{ "uuid",       required_argument, nullptr, 'u' },
		{ "version",    no_argument,       nullptr, 'v' },
		{ "wait",       no_argument,       nullptr, 'w' },
		{ "no-wait",    no_argument,       nullptr, 'W' },
		{ nullptr,      0,                 nullptr, 0   }
	};

	optind   = 1;
	optreset = 1;

	int ch;
	while((ch = getopt_long(argc, argv, "ac:dehl:m:p:rs:t:u:vw", longopts, nullptr)) != -1)
	{
		switch(ch)
		{
			case 'a': options.wait = false;               break;
			case 'c': options.clearMarks.push_back(optarg); break;
			case 'd':                                     break;
			case 'e': options.keepEscapes = true;         break;
			case 'E': options.keepEscapes = false;        break;
			case 'h': usage(stdout);                      exit(EX_OK);
			case 'l': append(optarg, options.lines);      break;
			case 'm': append(optarg, options.names);      break;
			case 'p': append(optarg, options.projects);   break;
			case 'r': options.addToRecent = true;         break;
			case 'R': options.addToRecent = false;        break;
			case 's': options.setMarks.push_back(optarg); break;
			case 't': append(optarg, options.types);      break;
			case 'v': fprintf(stdout, "%s %s\n", getprogname(), AppVersion); exit(EX_OK);
			case 'w': options.wait = true;                break;
			case 'W': options.wait = false;               break;

			case 'u':
			{
				if(!is_uuid(optarg))
					die(EX_USAGE, "invalid document identifier: %s", optarg);
				options.uuid = optarg;
			}
			break;

			default: // getopt_long() has printed an error
				exit(EX_USAGE);
		}
	}
	return optind;
}

static bool is_temporary_file (std::string const& path)
{
	std::string const resolved = path::resolve(path);
	return path::is_child(resolved, path::resolve("/tmp")) || path::is_child(resolved, path::resolve(path::temp()));
}

// ========
// = Main =
// ========

int main (int argc, char* argv[])
{
	drop_sudo_privileges();

	@autoreleasepool {
		options_t options;

		std::string const progname = getprogname();
		if(progname.size() > 5 && progname.compare(progname.size() - 5, 5, "_wait") == 0)
			options.wait = true;

		if(char const* mateFlags = getenv("MATEFLAGS"))
		{
			std::vector<std::string> words;
			std::istringstream stream(mateFlags);
			for(std::string word; stream >> word; )
				words.push_back(word);

			std::vector<char*> flags = { (char*)progname.c_str() };
			for(std::string& word : words)
				flags.push_back(word.data());
			flags.push_back(nullptr);
			parse_options(flags.size() - 1, flags.data(), options);
		}

		int const first = parse_options(argc, argv, options);

		// ==================
		// = Build targets =
		// ==================

		std::vector<target_t> targets;
		for(int i = first; i < argc; ++i)
		{
			std::string path = argv[i];
			if(path.empty())
				continue;

			if(path == "-")
			{
				targets.push_back({ target_t::kStdin, path });
				continue;
			}

			if(!path::is_absolute(path))
			{
				char* cwd = getcwd(nullptr, 0);
				if(!cwd)
					die(EX_OSERR, "unable to get current folder: %s", strerror(errno));
				path = path::join(cwd, path);
				free(cwd);
			}
			targets.push_back({ target_t::kPath, path });
		}

		char const* documentUUID = getenv("TM_DOCUMENT_UUID");
		if(documentUUID && !is_uuid(documentUUID))
			documentUUID = nullptr;

		std::string const defaultProject = options.projects.empty() ? (getenv("TM_PROJECT_UUID") ?: "") : options.projects.back();

		bool const stdinIsAPipe = isatty(STDIN_FILENO) == 0;
		if(targets.empty() && options.uuid == NULL_STR && (!options.setMarks.empty() || (!options.clearMarks.empty() && !options.lines.empty())) && documentUUID)
			options.uuid = documentUUID;

		if(targets.empty() && (options.uuid != NULL_STR || (options.setMarks.empty() && options.clearMarks.empty())))
		{
			if(options.uuid != NULL_STR)
				targets.push_back({ target_t::kDocument, options.uuid });
			else if(options.wait.value_or(false) || stdinIsAPipe)
				targets.push_back({ target_t::kStdin, "-" });
		}

		// ================
		// = Send request =
		// ================

		int const fd = connect_to_app(!targets.empty());
		reader_t reader(fd);

		std::string greeting;
		if(!reader.read_line(greeting))
			die(EX_PROTOCOL, "no reply from OakMate");

		auto const& lines = options.lines;
		auto const& setMarks = options.setMarks;
		auto const& clearMarks = options.clearMarks;

		if(!clearMarks.empty())
		{
			size_t const n = setMarks.empty() ? std::max({ clearMarks.size(), targets.size(), lines.size() }) : clearMarks.size();
			for(size_t i = 0; i < n; ++i)
			{
				std::string record = "clear-mark\r\n" + key_value("mark", clearMarks[i % clearMarks.size()]);
				if(!lines.empty() && setMarks.empty())
					record += key_value("line", lines[i % lines.size()]);
				if(!targets.empty())
					record += targets[i % targets.size()].reference();
				send(fd, record + "\r\n");
			}
		}

		if(!setMarks.empty() && !targets.empty() && !lines.empty())
		{
			size_t const n = std::max({ setMarks.size(), targets.size(), lines.size() });
			for(size_t i = 0; i < n; ++i)
			{
				std::string record = "set-mark\r\n" + key_value("mark", setMarks[i % setMarks.size()]) + key_value("line", lines[i % lines.size()]) + targets[i % targets.size()].reference();
				send(fd, record + "\r\n");
			}
		}

		if(clearMarks.empty() && setMarks.empty())
		{
			for(size_t i = 0; i < targets.size(); ++i)
			{
				target_t const& target = targets[i];
				send(fd, "open\r\n");

				std::string record;
				if(target.kind == target_t::kStdin)
				{
					if(!stdinIsAPipe)
						fprintf(stderr, "Reading from stdin, press ^D to stop\n");

					uint64_t total = 0;
					bool didStripEscapes = false;
					escape_state_t state = escape_state_t::kPlain;

					char buf[64 << 10];
					ssize_t len;
					while((len = read(STDIN_FILENO, buf, sizeof(buf))) != 0)
					{
						if(len == -1)
						{
							if(errno == EINTR)
								continue;
							die(EX_IOERR, "read: %s", strerror(errno));
						}

						if(!options.keepEscapes.value_or(false))
						{
							ssize_t const oldLen = std::exchange(len, remove_ansi_escapes(buf, buf + len, state) - buf);
							didStripEscapes = didStripEscapes || oldLen != len;
						}

						if(len)
						{
							send(fd, text::format("data: %zd\r\n", len));
							send(fd, std::string(buf, len));
							total += len;
						}
					}

					if(didStripEscapes && !options.keepEscapes.has_value())
						fprintf(stderr, "WARNING: Removed ANSI escape codes. Use -e/--[no-]escapes.\n");

					if(stdinIsAPipe && total == 0 && !options.wait.value_or(false) && documentUUID)
					{
						record += key_value("uuid", documentUUID);
					}
					else
					{
						bool const stdoutIsAPipe = isatty(STDOUT_FILENO) == 0;
						bool const wait = options.wait.value_or(stdoutIsAPipe);
						record += key_value("display-name",  i < options.names.size() ? options.names[i] : "untitled (stdin)");
						record += key_value("data-on-close", wait && stdoutIsAPipe ? "yes" : "no");
						record += key_value("wait",          wait ? "yes" : "no");
						record += key_value("re-activate",   wait ? "yes" : "no");
					}
				}
				else if(target.kind == target_t::kDocument)
				{
					record += key_value("uuid", target.value);
				}
				else
				{
					bool const wait = options.wait.value_or(false);
					record += key_value("path",         target.value);
					record += key_value("display-name", i < options.names.size() ? options.names[i] : "");
					record += key_value("wait",         wait ? "yes" : "no");
					record += key_value("re-activate",  wait ? "yes" : "no");

					std::string const name = path::name(target.value);
					if(!options.addToRecent.has_value() && !wait && !name.empty() && name.front() != '.' && !is_temporary_file(target.value))
						record += key_value("add-to-recents", "yes");
				}

				if(options.addToRecent.has_value())
					record += key_value("add-to-recents", *options.addToRecent ? "yes" : "no");

				record += key_value("selection",    i < lines.size()            ? lines[i]            : "");
				record += key_value("file-type",    i < options.types.size()    ? options.types[i]    : "");
				record += key_value("project-uuid", i < options.projects.size() ? options.projects[i] : defaultProject);
				send(fd, record + "\r\n");
			}
		}

		send(fd, ".\r\n");

		// ======================================================
		// = Wait for documents to close and write their content =
		// ======================================================

		enum { kCommand, kClose, kOther } state = kCommand;

		std::string line;
		while(reader.read_line(line))
		{
			if(line.empty())
			{
				state = kCommand;
			}
			else if(state == kCommand)
			{
				state = line == "close" ? kClose : kOther;
			}
			else if(line.compare(0, 6, "data: ") == 0)
			{
				uint64_t len;
				if(!parse_number(line.c_str() + 6, UINT64_MAX, len))
					die(EX_PROTOCOL, "invalid reply from OakMate");
				if(!reader.copy(len, state == kClose ? STDOUT_FILENO : -1))
					break;
			}
		}

		close(fd);
	}
	return EX_OK;
}

#ifndef IO_FSEVENTS_H_7RK2PQ4D
#define IO_FSEVENTS_H_7RK2PQ4D

#include <oak/misc.h>

// An FSEvents stream scheduled on a private dispatch queue. Events are
// delivered to the handler on the main queue, and never after the stream has
// been destroyed.

namespace fs
{
	struct event_t
	{
		std::string path; // Without a trailing slash
		uint64_t id;
		FSEventStreamEventFlags flags;
	};

	struct event_stream_t
	{
		typedef void(^handler_t)(std::vector<event_t> const& events);

		event_stream_t (std::vector<std::string> const& paths, handler_t handler, uint64_t sinceEventId = kFSEventStreamEventIdSinceNow, CFTimeInterval latency = 1, FSEventStreamCreateFlags flags = kFSEventStreamCreateFlagNone);
		~event_stream_t ();

		event_stream_t (event_stream_t const&) = delete;
		event_stream_t& operator= (event_stream_t const&) = delete;

		explicit operator bool () const { return _stream; }

		// Deliver pending events now instead of after the latency
		void flush ();

		struct state_t; // Shared with the FSEvents callback

	private:
		FSEventStreamRef _stream = nullptr;
		std::shared_ptr<state_t> _state;
	};

	typedef std::shared_ptr<event_stream_t> event_stream_ptr;

} /* fs */

#endif /* end of include guard: IO_FSEVENTS_H_7RK2PQ4D */

#include "fsevents.h"
#include <cf/cf.h>

namespace fs
{
	struct event_stream_t::state_t
	{
		state_t (handler_t handler) : handler(Block_copy(handler)) { }
		~state_t () { Block_release(handler); }

		handler_t handler;
		std::atomic<bool> alive = true;
	};

	namespace
	{
		struct context_t
		{
			std::shared_ptr<event_stream_t::state_t> state;
		};

		void callback (ConstFSEventStreamRef streamRef, void* info, size_t numEvents, void* eventPaths, FSEventStreamEventFlags const eventFlags[], FSEventStreamEventId const eventIds[])
		{
			std::vector<event_t> events;
			for(size_t i = 0; i < numEvents; ++i)
			{
				std::string path = ((char const* const*)eventPaths)[i];
				if(path.size() > 1 && path.back() == '/')
					path.pop_back();
				events.push_back({ path, eventIds[i], eventFlags[i] });
			}

			auto state = ((context_t*)info)->state;
			dispatch_async(dispatch_get_main_queue(), ^{
				if(state->alive)
					state->handler(events);
			});
		}

		void const* retain_context (void const* info)
		{
			return info;
		}

		void release_context (void const* info)
		{
			delete (context_t const*)info;
		}
	}

	event_stream_t::event_stream_t (std::vector<std::string> const& paths, handler_t handler, uint64_t sinceEventId, CFTimeInterval latency, FSEventStreamCreateFlags flags) : _state(std::make_shared<state_t>(handler))
	{
		if(paths.empty())
			return;

		FSEventStreamContext context = { 0, new context_t{ _state }, &retain_context, &release_context, nullptr };
		if(_stream = FSEventStreamCreate(kCFAllocatorDefault, &callback, &context, cf::wrap(paths), sinceEventId, latency, flags))
		{
			static dispatch_queue_t queue = dispatch_queue_create("com.isztld.oakmate.fsevents", DISPATCH_QUEUE_SERIAL);
			FSEventStreamSetDispatchQueue(_stream, queue);
			if(!FSEventStreamStart(_stream))
			{
				os_log_error(OS_LOG_DEFAULT, "Failed to start FSEvents stream for %{public}s", paths.front().c_str());
				FSEventStreamInvalidate(_stream);
				FSEventStreamRelease(_stream);
				_stream = nullptr;
			}
		}
		else
		{
			os_log_error(OS_LOG_DEFAULT, "Failed to create FSEvents stream for %{public}s", paths.front().c_str());
		}
	}

	event_stream_t::~event_stream_t ()
	{
		_state->alive = false;
		if(_stream)
		{
			FSEventStreamStop(_stream);
			FSEventStreamInvalidate(_stream);
			FSEventStreamRelease(_stream);
		}
	}

	void event_stream_t::flush ()
	{
		if(_stream)
			FSEventStreamFlushAsync(_stream);
	}

} /* fs */

// Exposes the ‘TextMate’ object to HTML output (only for pages loaded from file: URLs).
//
//   TextMate.system(command, handler)  Run a shell command, see below.
//   TextMate.log(message)              Write a message to the system log.
//   TextMate.open(path, options)       Open a file in TextMate. Options is a selection string or a line number.
//   TextMate.isBusy                    Show the busy spinner in the status bar while true.
//   TextMate.progress                  Value (0-1) of the progress indicator.
//
// TextMate.system() without a handler (or with null) runs the command synchronously and returns an object with
// outputString, errorString, and status. With a handler the command runs asynchronously and the returned object
// also has onreadoutput/onreaderror (called with new output), write(string), close() (closes stdin), and cancel().
// The handler is called with this object once the command has finished.

(function () {
	if(window.location.protocol !== "file:" || window.TextMate !== undefined)
		return;

	const post = (command, payload) => window.webkit.messageHandlers.textmate.postMessage({ command: command, payload: payload });
	const commands = new Map();
	let nextCommandId = 1, busy = false, progress = 0;

	class ShellCommand {
		constructor (id, handler) {
			this._id           = id;
			this._handler      = handler;
			this._onreadoutput = null;
			this._onreaderror  = null;
			this.outputString  = "";
			this.errorString   = "";
			this.status        = 0;
		}

		get onreadoutput ()   { return this._onreadoutput; }
		set onreadoutput (fn) { this._onreadoutput = fn; if(typeof fn === "function") fn.call(fn, this.outputString); }
		get onreaderror ()    { return this._onreaderror; }
		set onreaderror (fn)  { this._onreaderror = fn; if(typeof fn === "function") fn.call(fn, this.errorString); }

		write (str) { post("write", { id: this._id, data: String(str) }); }
		close ()    { post("closeInput", { id: this._id }); }
		cancel ()   { commands.delete(this._id); post("cancel", { id: this._id }); }

		_didRead (isError, str) {
			const fn = isError ? this._onreaderror : this._onreadoutput;
			if(typeof fn === "function") {
				// With a handler the string only holds the most recent output
				if(isError) this.errorString = str; else this.outputString = str;
				fn.call(fn, str);
			} else {
				if(isError) this.errorString += str; else this.outputString += str;
			}
		}

		_didExit (status) {
			commands.delete(this._id);
			this.status = status;
			if(typeof this._handler === "function")
				this._handler.call(this._handler, this);
		}
	}

	const TextMate = {
		system (command, handler) {
			if(typeof handler !== "function") {
				const res = prompt("x-txmt-bridge", JSON.stringify({ command: "system", payload: { command: String(command) } }));
				const obj = (res && JSON.parse(res)) || { outputString: "", errorString: "", status: -1 };
				return Object.assign(obj, { write () { }, close () { }, cancel () { } });
			}

			const id = nextCommandId++;
			const cmd = new ShellCommand(id, handler);
			commands.set(id, cmd);
			post("system", { id: id, command: String(command) });
			return cmd;
		},

		log (message) {
			post("log", { message: String(message) });
		},

		open (path, options) {
			post("open", { path: String(path), options: (typeof options === "number" || typeof options === "string") ? options : null });
		},

		get isBusy ()    { return busy; },
		set isBusy (v)   { busy = !!v; post("setBusy", { value: busy }); },
		get progress ()  { return progress; },
		set progress (v) { progress = Number(v) || 0; post("setProgress", { value: progress }); },
	};

	// Called by TextMate to deliver output from asynchronous commands
	Object.defineProperty(TextMate, "_commandEvent", {
		value: function (id, type, data) {
			const cmd = commands.get(id);
			if(cmd === undefined)
				return;
			if(type === "exit")
				cmd._didExit(data);
			else
				cmd._didRead(type === "error", data);
		}
	});

	Object.defineProperty(window, "TextMate", { value: TextMate, configurable: true });
})();

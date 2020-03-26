/*
 * Copyright 2016 Software Freedom Conservancy Inc.
 * Copyright 2018 Michael Gratton <mike@vee.net>
 *
 * This software is licensed under the GNU Lesser General Public License
 * (version 2.1 or later).  See the COPYING file in this distribution.
 */

/**
 * A representation of an IMAP command (request).
 *
 * A Command is created by the caller and then submitted to a {@link ClientSession} or
 * {@link ClientConnection} for transmission to the server.  In response, one or more
 * {@link ServerResponse}s are returned, generally zero or more {@link ServerData}s followed by
 * a completion {@link StatusResponse}.  Untagged {@link StatusResponse}s may also be returned,
 * depending on the Command.
 *
 * See [[http://tools.ietf.org/html/rfc3501#section-6]]
 */
public abstract class Geary.Imap.Command : BaseObject {

    /**
     * Default timeout to wait for a server response for a command.
     */
    public const uint DEFAULT_RESPONSE_TIMEOUT_SEC = 30;


    /**
     * All IMAP commands are tagged with an identifier assigned by the client.
     *
     * Note that this is not immutable.  The general practice is to use an unassigned Tag
     * up until the {@link Command} is about to be transmitted, at which point a Tag is
     * assigned.  This allows for all commands to be issued in Tag "order".  This generally makes
     * tracing network traffic easier.
     *
     * @see Tag.get_unassigned
     * @see assign_tag
     */
    public Tag tag { get; private set; }

    /**
     * The name (or "verb") of this command.
     */
    public string name { get; private set; }

    /**
     * Number of seconds to wait for a server response to this command.
     */
    public uint response_timeout {
        get {
            return this._response_timeout;
        }
        set {
            this._response_timeout = value;
            this.response_timer.interval = value;
        }
    }
    private uint _response_timeout = DEFAULT_RESPONSE_TIMEOUT_SEC;

    /** The status response for the command, once it has been received. */
    public StatusResponse? status { get; private set; default = null; }

    /**
     * The command's arguments as parameters.
     *
     * Subclassess may append arguments to this before {@link send} is
     * called, ideally from their constructors.
     */
    protected ListParameter args {
        get; private set; default = new RootParameters();
    }

    /**
     * Timer used to check for a response within {@link response_timeout}.
     */
    protected TimeoutManager response_timer { get; private set; }

    private Geary.Nonblocking.Semaphore complete_lock =
        new Geary.Nonblocking.Semaphore();

    private ImapError? cancelled_cause = null;

    private Geary.Nonblocking.Spinlock? literal_spinlock = null;
    private GLib.Cancellable? literal_cancellable = null;


    /**
     * Fired when the response timeout for this command has been reached.
     */
    public signal void response_timed_out();

    /**
     * Constructs a new command with an unassigned tag.
     *
     * Any arguments provided here will be converted to appropriate
     * string arguments
     *
     * @see Tag
     */
    protected Command(string name, string[]? args = null) {
        this.tag = Tag.get_unassigned();
        this.name = name;
        if (args != null) {
            foreach (string arg in args) {
                this.args.add(Parameter.get_for_string(arg));
            }
        }

        this.response_timer = new TimeoutManager.seconds(
            this._response_timeout, on_response_timeout
        );
    }

    public bool has_name(string name) {
        return Ascii.stri_equal(this.name, name);
    }

    /**
     * Assign a Tag to this command, if currently unassigned.
     *
     * Can only be called on a Command that holds an unassigned tag,
     * and hence this can only be called once at most. Throws an error
     * if already assigned or if the supplied tag is unassigned.
     */
    internal void assign_tag(Tag new_tag) throws ImapError {
        if (this.tag.is_assigned()) {
            throw new ImapError.NOT_SUPPORTED(
                "%s: Command tag is already assigned", to_brief_string()
            );
        }
        if (!new_tag.is_assigned()) {
            throw new ImapError.NOT_SUPPORTED(
                "%s: New tag is not assigned", to_brief_string()
            );
        }

        this.tag = new_tag;
    }

    /**
     * Serialises this command for transmission to the server.
     *
     * This will serialise its tag, name and arguments (if
     * any). Arguments are treated as strings and escaped as needed,
     * including being encoded as a literal. If any literals are
     * required, this method will yield until a command continuation
     * has been received, when it will resume the same process.
     */
    internal virtual async void send(Serializer ser,
                                     GLib.Cancellable cancellable)
        throws GLib.Error {
        this.response_timer.start();
        this.tag.serialize(ser, cancellable);
        ser.push_space(cancellable);
        ser.push_unquoted_string(this.name, cancellable);

        if (this.args != null) {
            foreach (Parameter arg in this.args.get_all()) {
                ser.push_space(cancellable);
                arg.serialize(ser, cancellable);

                LiteralParameter literal = arg as LiteralParameter;
                if (literal != null) {
                    // Need to manually flush after serialising the
                    // literal param, so it actually gets to the
                    // server
                    yield ser.flush_stream(cancellable);

                    if (this.literal_spinlock == null) {
                        // Lazily create these since they usually
                        // won't be needed
                        this.literal_cancellable = new GLib.Cancellable();
                        this.literal_spinlock = new Geary.Nonblocking.Spinlock(
                            this.literal_cancellable
                        );
                    }

                    // Will get notified via continuation_requested
                    // when server indicated the literal can be sent.
                    yield this.literal_spinlock.wait_async(cancellable);

                    // Buffer size is dependent on timeout, since we
                    // need to ensure we can send a full buffer before
                    // the timeout is up. v.92 56k baud modems have
                    // theoretical max upload of 48kbit/s and GSM 2G
                    // 40kbit/s, but typical is usually well below
                    // that, so assume a low end of 1kbyte/s. Hence
                    // buffer size needs to be less than or equal to
                    // (response_timeout * 1)k, rounded down to the
                    // nearest power of two.
                    uint buf_size = 1;
                    while (buf_size <= this.response_timeout) {
                        buf_size <<= 1;
                    }
                    buf_size >>= 1;

                    uint8[] buf = new uint8[buf_size * 1024];
                    GLib.InputStream data = literal.value.get_input_stream();
                    try {
                        while (true) {
                            size_t read;
                            yield data.read_all_async(
                                buf, Priority.DEFAULT, cancellable, out read
                            );
                            if (read <= 0) {
                                break;
                            }

                            buf.length = (int) read;
                            yield ser.push_literal_data(buf, cancellable);
                            this.response_timer.start();
                        }
                    } finally {
                        try {
                            yield data.close_async();
                        } catch (GLib.Error err) {
                            // Oh well
                        }
                    }
                }
            }
        }

        ser.push_eol(cancellable);
    }

    /**
     * Check for command-specific server responses after sending.
     *
     * This method is called after {@link send} and after {@link
     * ClientSession} has signalled the command has been sent, but
     * before the next command is processed. It allows command
     * implementations (e.g. {@link IdleCommand}) to asynchronously
     * wait for some kind of response from the server before allowing
     * additional commands to be sent.
     *
     * Most commands will not need to override this, and it by default
     * does nothing.
     */
    internal virtual async void send_wait(Serializer ser,
                                          GLib.Cancellable cancellable)
        throws GLib.Error {
        // Nothing to do by default
    }

    /**
     * Yields until the command has been completed or cancelled.
     *
     * Throws an error if the command or the cancellable argument is
     * cancelled, if the command timed out, or if the command's
     * response was bad.
     */
    public async void wait_until_complete(GLib.Cancellable? cancellable)
        throws GLib.Error {
        yield this.complete_lock.wait_async(cancellable);

        if (this.cancelled_cause != null) {
            throw this.cancelled_cause;
        }

        check_has_status();

        // Since this is part of the public API, perform a strict
        // check on the status code.
        if (this.status.status == Status.BAD) {
            throw new ImapError.SERVER_ERROR(
                "%s: Command failed: %s",
                to_brief_string(),
                this.status.to_string()
            );
        }
    }

    /**
     * Throws an error if this command's status response is NO or BAD.
     *
     * If the response is NO, an ImapError.OPERATIONAL_ERROR is
     * thrown. If the response is BAD, an ImapError.SERVER_ERROR is
     * thrown. If a specific response code is set, another more
     * appropriate exception may be thrown. The given command is used
     * to provide additional context information in case an error is
     * thrown.
     */
    public void throw_on_error() throws ImapError {
        StatusResponse? response = this.status;
        if (response != null && response.status in new Status[] { BAD, NO }) {
            ResponseCode? code = response.response_code;
            if (code != null) {
                ResponseCodeType code_type = code.get_response_code_type();
                switch (code_type.value) {
                case ResponseCodeType.ALREADYEXISTS:
                    throw new ImapError.SERVER_ERROR(
                        "%s: Already exists: %s",
                        to_brief_string(),
                        response.to_string()
                    );

                case ResponseCodeType.AUTHENTICATIONFAILED:
                    throw new ImapError.UNAUTHENTICATED(
                        "%s: Bad credentials: %s",
                        to_brief_string(),
                        response.to_string()
                    );

                case ResponseCodeType.AUTHORIZATIONFAILED:
                    throw new ImapError.SERVER_ERROR(
                        "%s: Not authorised: %s",
                        to_brief_string(),
                        response.to_string()
                    );

                case ResponseCodeType.CANNOT:
                    throw new ImapError.SERVER_ERROR(
                        "%s: Cannot be performed: %s",
                        to_brief_string(),
                        response.to_string()
                    );

                case ResponseCodeType.LIMIT:
                    throw new ImapError.SERVER_ERROR(
                        "%s: Hit limit: %s",
                        to_brief_string(),
                        response.to_string()
                    );

                case ResponseCodeType.NOPERM:
                    throw new ImapError.SERVER_ERROR(
                        "%s: Not permitted by ACL: %s",
                        to_brief_string(),
                        response.to_string()
                    );

                case ResponseCodeType.NONEXISTENT:
                    throw new ImapError.SERVER_ERROR(
                        "%s: Does not exist: %s",
                        to_brief_string(),
                        response.to_string()
                    );

                case ResponseCodeType.OVERQUOTA:
                    throw new ImapError.SERVER_ERROR(
                        "%s: Over quota: %s",
                        to_brief_string(),
                        response.to_string()
                    );

                case ResponseCodeType.UNAVAILABLE:
                    throw new ImapError.UNAVAILABLE(
                        "%s: Server is unavailable: %s",
                        to_brief_string(),
                        response.to_string()
                    );
                }
            }

            // No interesting response code, so just throw a generic
            // error
            switch (response.status) {
            case Status.NO:
                throw new ImapError.OPERATIONAL_ERROR(
                    "%s: Operational server error: %s",
                    to_brief_string(),
                    response.to_string()
                );

            case Status.BAD:
                throw new ImapError.SERVER_ERROR(
                    "%s: Fatal server error: %s",
                    to_brief_string(),
                    response.to_string()
                );
            }
        }
    }

    public virtual string to_string() {
        string args = this.args.to_string();
        return (Geary.String.is_empty(args))
            ? "%s %s".printf(this.tag.to_string(), this.name)
            : "%s %s %s".printf(this.tag.to_string(), this.name, args);
    }

    /**
     * Called when a tagged status response is received for this command.
     *
     * This will update the command's {@link status} property, then
     * throw an error if it does not indicate a successful completion.
     */
    internal virtual void completed(StatusResponse new_status)
        throws ImapError {
        if (this.status != null) {
            cancel_send();
            throw new ImapError.SERVER_ERROR(
                "%s: Duplicate status response received: %s",
                to_brief_string(),
                status.to_string()
            );
        }

        this.status = new_status;
        this.response_timer.reset();
        this.complete_lock.blind_notify();
        cancel_send();

        check_has_status();
    }

    /**
     * Cancels this command due to a network or server disconnect.
     *
     * When this method is called, all locks will be released,
     * including {@link wait_until_complete}, which will then throw a
     * `GLib.IOError.CANCELLED` error.
     */
    internal virtual void disconnected(string reason) {
        cancel(new ImapError.NOT_CONNECTED("%s: %s", to_brief_string(), reason));
    }

    /**
     * Called when tagged server data is received for this command.
     */
    internal virtual void data_received(ServerData data)
        throws ImapError {
        if (this.status != null) {
            cancel_send();
            throw new ImapError.SERVER_ERROR(
                "%s: Server data received when command already complete: %s",
                to_brief_string(),
                data.to_string()
            );
        }

        this.response_timer.start();
    }

    /**
     * Called when a continuation was requested by the server.
     *
     * This will notify the command's literal spinlock so that if
     * {@link send} is waiting to send a literal, it will do so
     * now.
     */
    internal virtual void
        continuation_requested(ContinuationResponse continuation)
        throws ImapError {
        if (this.status != null) {
            cancel_send();
            throw new ImapError.SERVER_ERROR(
                "%s: Continuation requested when command already complete",
                to_brief_string()
            );
        }

        if (this.literal_spinlock == null) {
            cancel_send();
            throw new ImapError.SERVER_ERROR(
                "%s: Continuation requested but no literals available",
                to_brief_string()
            );
        }

        this.response_timer.start();
        this.literal_spinlock.blind_notify();
    }

    /** Returns the command tag and name for debugging. */
    internal string to_brief_string() {
        return "%s %s".printf(this.tag.to_string(), this.name);
    }

    /**
     * Cancels any existing serialisation in progress.
     *
     * When this method is called, any non I/O related process
     * blocking the blocking {@link send} must be cancelled.
     */
    protected virtual void cancel_send() {
        if (this.literal_cancellable != null) {
            this.literal_cancellable.cancel();
        }
    }

    private void cancel(ImapError cause) {
        cancel_send();
        this.cancelled_cause = cause;
        this.response_timer.reset();
        this.complete_lock.blind_notify();
    }

    private void check_has_status() throws ImapError {
        if (this.status == null) {
            throw new ImapError.SERVER_ERROR(
                "%s: No command response was received",
                to_brief_string()
            );
        }

        if (!this.status.is_completion) {
            throw new ImapError.SERVER_ERROR(
                "%s: Command status response is not a completion: %s",
                to_brief_string(),
                this.status.to_string()
            );
        }
    }

    private void on_response_timeout() {
        cancel(
            new ImapError.TIMED_OUT("%s: Command timed out", to_brief_string())
        );
        response_timed_out();
    }

}

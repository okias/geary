/*
 * Copyright © 2020 Michael Gratton <mike@vee.net>
 *
 * This software is licensed under the GNU Lesser General Public License
 * (version 2.1 or later). See the COPYING file in this distribution.
 */

class Geary.Imap.CommandTest : TestCase {


    private class TestCommand : Command {

        public TestCommand() {
            base("TEST");
        }

    }


    public CommandTest() {
        base("Geary.Imap.CommandTest");
        add_test("throw_on_error", throw_on_error);
    }

    public void throw_on_error() throws GLib.Error {
        var test_article = newCompleteTestCommand(OK, null);
        test_article.throw_on_error();

        test_article = newCompleteTestCommand(NO, null);
        try {
            test_article.throw_on_error();
            assert_not_reached();
        } catch (ImapError.OPERATIONAL_ERROR err) {
            // expected
        }

        test_article = newCompleteTestCommand(BAD, null);
        try {
            test_article.throw_on_error();
            assert_not_reached();
        } catch (ImapError.SERVER_ERROR err) {
            // expected
        }

        test_article = newCompleteTestCommand(
            NO, ResponseCodeType.AUTHENTICATIONFAILED
        );
        try {
            test_article.throw_on_error();
            assert_not_reached();
        } catch (ImapError.UNAUTHENTICATED err) {
            // expected
        }

        test_article = newCompleteTestCommand(
            NO, ResponseCodeType.UNAVAILABLE
        );
        try {
            test_article.throw_on_error();
            assert_not_reached();
        } catch (ImapError.UNAVAILABLE err) {
            // expected
        }
    }

    private Command newCompleteTestCommand(Status status,
                                           string? response_code)
        throws GLib.Error {
        var command = new TestCommand();
        command.assign_tag(new Tag("t001"));

        ResponseCode? code = null;
        if (response_code != null) {
            code = new ResponseCode();
            code.add(new AtomParameter(response_code));
        }

        try {
            command.completed(new StatusResponse(command.tag, status, code));
        } catch (ImapError.SERVER_ERROR err) {
            if (status != BAD) {
                throw err;
            }
        }
        return command;
    }

}

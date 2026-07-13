// SSHProgname.c — Moshroom
//
// OpenSSH's logging core (log.c) references the BSD global `__progname` to prefix
// diagnostic messages. On Apple platforms `__progname` is a NON-PUBLIC runtime symbol:
// leaving it as an unresolved import in the SSH framework makes App Store static
// analysis reject the upload with `ITMS-90338: Non-public API usage`
// (`Frameworks/SSH.framework/SSH: __progname`).
//
// Defining the symbol locally turns that dangling import into our own data symbol, so
// the framework no longer references Apple's private `__progname`. The value is cosmetic
// (it is only ever read as a log-line prefix by OpenSSH's key-parsing code, which
// Moshroom drives directly rather than as a command-line program).
//
// This is the standard, documented fix for OpenSSH's `__progname` on iOS/Catalyst.

static char moshroom_progname[] = "moshroom";
char *__progname = moshroom_progname;

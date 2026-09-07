// Jump-to-session-window, the macOS panel's hover button. Not available on
// Windows yet: handing foreground to another process from a WS_EX_NOACTIVATE
// window needs AllowSetForegroundWindow plumbing per terminal, and the hook
// only started recording Windows Terminal identity (host.wtSessionId) with
// this port. Kept as the single place to fill in later.
namespace CcGlance;

internal sealed record JumpTarget(string AppName)
{
    public static JumpTarget? From(SessionState session) => null;
}

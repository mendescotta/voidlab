# Prefer chimerautils' (FreeBSD-derived) coreutils in interactive login
# shells. System scripts keep GNU coreutils from /usr/bin: dracut and xbps
# rely on GNU-only options (e.g. stat -c).
case ":$PATH:" in
	*:/usr/lib/chimerautils/coreutils:*) ;;
	*) PATH="/usr/lib/chimerautils/coreutils:$PATH" ;;
esac
export PATH

# The dinit base ships nano instead of vi, but visudo, vipw and crontab -e still fall
# back to vi when EDITOR is unset. Default it here; any user setting wins.
: "${EDITOR:=nano}"
export EDITOR

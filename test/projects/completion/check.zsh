# Capture the completion API calls without needing a terminal in the test runner.
compdef() { :; }
source "$1"
compadd() {
    [[ $1 == -V && $2 == dotcmd && $3 == -d && $4 == descriptions && $5 == -- ]] || exit 1
    display=("${descriptions[@]}")
    shift 5
    result=("$@")
}
compset() { [[ $1 == -p ]] || exit 1; removed=$2; }
_path_files() { result+=(paths "$@"); }
check() {
    local PREFIX=$1 expected=$2
    shift 2
    local -a words=(./.cmd "$@" "$PREFIX") result=()
    local CURRENT=${#words}
    _dotcmd_complete
    [[ "${(j:|:)result}" == "$expected" ]] || { print -r -- "$PREFIX: ${(j:|:)result}"; exit 1; }
}
check b build-docs
[[ $display[1] == 'build-docs  Build documentation' ]] || exit 1
typeset -a colors
zstyle -a ':completion:*:default' list-colors colors
[[ $colors[1] == '(dotcmd)=(#b)(*)  (*)=0=1=2' ]] || exit 1
check '--mode=d' '--mode=debug' docs
check 'two w' 'two words' docs --mode
check hé héllo docs --mode
check two 'paths|-/' docs --directory
check '--file=two' paths docs
[[ $removed == 7 ]] || exit 1
check '' '' empty

check '--v' '--verbose|paths' forward

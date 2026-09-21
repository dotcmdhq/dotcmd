# Capture the completion API calls without needing a terminal in the test runner.
compdef() { :; }
source "$1"
compadd() { shift 3; result=("$@"); }
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
check '--mode=d' '--mode=debug' docs
check 'two w' 'two words' docs --mode
check hé héllo docs --mode
check two 'paths|-/' docs --directory
check '--file=two' paths docs
[[ $removed == 7 ]] || exit 1
check '' '' empty

check '--v' '--verbose|paths' forward

$ErrorActionPreference = "Stop"
$commit = "08659901c43b51de735740f1cf61bb82fbe0c4e4"

git submodule update --init --recursive -- third_party/llama.cpp
$head = git -C third_party/llama.cpp rev-parse HEAD
if ($head.Trim() -ne $commit) {
  throw "llama.cpp submodule is not at the trusted commit"
}
$status = git -C third_party/llama.cpp status --porcelain --untracked-files=no
if ($status) {
  throw "llama.cpp checkout is dirty after bootstrap"
}

Write-Output "Pinned llama.cpp at $commit"

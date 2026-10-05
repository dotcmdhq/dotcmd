# Clojure

Run Clojure without installing Java or the Clojure CLI. The `.cmd.lua` downloads
a pinned Liberica JDK and Clojure CLI through the published plugins.

From this directory, start a REPL:

```sh
./.cmd clj
```

Or evaluate an expression:

```sh
./.cmd clj -Srepro -M -e "(println (+ 40 2))"
```

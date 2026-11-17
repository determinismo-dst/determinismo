;; The project's own C++ (include/detviz.hpp: the window, its fonts, the drawing primitives and
;; the recording) on jank's include path.
(require '[babashka.fs :as fs])

(println (str "jank-build::include-dir=" (fs/path (:src-dir *input*) "include")))

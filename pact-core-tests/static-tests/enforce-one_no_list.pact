(module m g (defcap g () true)
  (defun enforce-cap ()
    (enforce-one "foo" 1)
    )
  )

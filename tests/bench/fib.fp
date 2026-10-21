; Naive doubly recursive Fibonacci of 18.
(
  ($x x)                       $force
  (force cswap $_ force)       $if
  ($f $t $c $fn ^f ^t ^c fn)   $endif
  ()                           $[
  ()                           $]
  ($x $y ^x ^y)                $swap
  (0 swap - -)                 $+
  ($f ($x (^x x) f) ($x (^x x) f) force) $Y
  ($g (^g Y))                  $rec

  ($self $n
    ^if [ ^n 0 eq ] 0 (
      ^if [ ^n 1 eq ] 1 ([ ^n 1 - ] self [ ^n 2 - ] self +) endif
    ) endif
  ) rec $fib
  18 fib print
)

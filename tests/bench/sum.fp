; Sums 1..5000 with recursion that is not a tail call.
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

  ($self $n ^if [ ^n 0 eq 0 ] ([ ^n 1 - ] self ^n +) endif) rec $sum
  5000 sum print
)

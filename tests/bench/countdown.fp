; Counts down from 10000 with a self-call in the else branch.
(
  ($x x)                       $force
  (force cswap $_ force)       $if
  ($f $t $c $fn ^f ^t ^c fn)   $endif
  ()                           $[
  ()                           $]
  ($f ($x (^x x) f) ($x (^x x) f) force) $Y
  ($g (^g Y))                  $rec

  ($self $n ^if [ ^n 0 eq 0 ] ([ ^n 1 - ] self) endif) rec $count
  10000 count print
)

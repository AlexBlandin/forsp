   …\code\third_party\forsp        v0.12.0  11:54 ♥  build-windows-zig-strict.cmd
build-windows-zig-strict.cmd
forsp.c:65:3: error: anonymous unions are a C11 extension [-Werror,-Wc11-extensions]
   65 |   union {
      |   ^
forsp.c:246:5: error: void function 'skip_white_and_comments' should not return void expression [-Werror,-Wpedantic]
  246 |     return skip_white_and_comments(); // tail-call loop
      |     ^      ~~~~~~~~~~~~~~~~~~~~~~~~~
forsp.c:253:12: error: declaration shadows a local variable [-Werror,-Wshadow]
  253 |       char c = peek();
      |            ^
forsp.c:240:8: note: previous declaration is here
  240 |   char c = peek();
      |        ^
forsp.c:258:5: error: void function 'skip_white_and_comments' should not return void expression [-Werror,-Wpedantic]
  258 |     return skip_white_and_comments(); // tail-call loop
      |     ^      ~~~~~~~~~~~~~~~~~~~~~~~~~
forsp.c:402:23: error: format specifies type 'void *' but the argument has type 'obj_t *' (aka 'struct obj *') [-Werror,-Wformat-pedantic]
  402 |       printf(", %p>", obj->clos.env);
      |                 ~~    ^~~~~~~~~~~~~
forsp.c:405:26: error: format specifies type 'void *' but the argument has type 'void (*)(obj_t **)' (aka 'void (*)(struct obj **)')
      [-Werror,-Wformat-pedantic]
  405 |       printf("PRIM<%p>", obj->prim.func);
      |                    ~~    ^~~~~~~~~~~~~~
forsp.c:466:11: error: a function declaration without a prototype is deprecated in all versions of C [-Werror,-Wstrict-prototypes]
  466 | obj_t *pop()
      |           ^
      |            void
forsp.c:513:7: error: void function 'eval' should not return void expression [-Werror,-Wpedantic]
  513 |       return compute(val->clos.body, val->clos.env);
      |       ^      ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
forsp.c:515:7: error: void function 'eval' should not return void expression [-Werror,-Wpedantic]
  515 |       return val->prim.func(env);
      |       ^      ~~~~~~~~~~~~~~~~~~~
forsp.c:517:7: error: void function 'eval' should not return void expression [-Werror,-Wpedantic]
  517 |       return push(val);
      |       ^      ~~~~~~~~~
forsp.c:520:5: error: void function 'eval' should not return void expression [-Werror,-Wpedantic]
  520 |     return push(make_clos(expr, *env));
      |     ^      ~~~~~~~~~~~~~~~~~~~~~~~~~~~
forsp.c:522:5: error: void function 'eval' should not return void expression [-Werror,-Wpedantic]
  522 |     return push(expr);
      |     ^      ~~~~~~~~~~
12 errors generated.
Plover
======

[![CI](https://github.com/swift-nav/plover/actions/workflows/ci.yaml/badge.svg)](https://github.com/swift-nav/plover/actions/workflows/ci.yaml)
[![Package version][plover-hackage-img]][plover-hackage]
[![Dependency status][plover-hackage-deps-img]][plover-hackage-deps]

Plover is an embedded Haskell DSL for compiling linear algebra into robust,
efficient C code suitable for running on embedded systems.

Plover generates code free of dynamic memory allocation and provides compile
time checking of matrix and vector shapes using a lightweight dependant type
system.

Plover also aims to make use of sparse structure present in many real world
linear algebra problems to generate more efficient code.

 - `Plover.Types` contains the AST for the DSL.
 - `Plover.Expressions` contains a number of example expressions.
 - `Plover.Reduce` contains the main compiler.
 - `Plover.Macros` contains DSL utilities.

Installation
------------

First, install [Stack](http://haskellstack.org) or [Haskell Platform](https://www.haskell.org/platform/). Key is having GHC 7.10+ available.

Check out the `plover` source:

```
$ git clone https://github.com/swift-nav/plover.git
$ cd plover
```

Then use one of the two available build methods.

## Stack build

```
$ stack build
```

Run the test suite (requires gcc):

```
$ stack test
```

Installation of the `plover` binary into `~/.local/bin`

```
$ stack build --copy-bins
```

or

```
# (equivalent to previous command)
$ stack install
```


## (Alternative Installation Method) Cabal sandbox build

Using a cabal sandbox keeps any dependencies isolated so you don't
have to worry about conflicts with other versions you may have on your system.

```
$ cabal sandbox init
```

Install the dependencies into the sandbox:

```
$ cabal install happy alex
$ cabal install --only-dependencies --enable-tests
```

Run the test suite (requires gcc):

```
$ cabal test --show-details=streaming
```

Usage
-----

See
http://swift-nav.github.io/plover/guide.html

[plover-github]: https://github.com/swift-nav/plover
[plover-hackage-img]: https://img.shields.io/hackage/v/plover.svg?style=flat
[plover-hackage]: https://hackage.haskell.org/package/plover
[plover-hackage-deps-img]: https://img.shields.io/hackage-deps/v/plover.svg?style=flat
[plover-hackage-deps]: http://packdeps.haskellers.com/feed?needle=plover

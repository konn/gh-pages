---
title: F4, F5 アルゴリズムに関するサーベイ（A survey on F_4 and F_5 algorithms）
author: 石井大海
description: Gröbner基底の効率的な計算法である F4, F5 アルゴリズムに関するサーベイ、メモ（A note on F4 and F5 algorithms to efficiently compute Gröbner bases）。
tag: 数学, 計算機代数, GSoC 2014, Gröbner基底
---

F_5 algorithm
=============

Plan
----
1. Because [the original paper][Orig] includes many errors and lacks strictness,
   read [Steger's thesis][Rev] instead first.
2. Then read [F5C][F5C] paper to improve it.
3. Read [the paper on termination][Term] and apply its argument to F5C.

Current progress
----------------
* Reading [Steger's thesis][Rev]. (2014/04/29)
* Implementing F_5, but is not yet working correctly. (2014/05/25)
    * It turns out that F_5 is for homogeneous ideals, so
	  I'm planning to read [Eder][Anal] and implement similar algorithm
	  for inhomogeneous ideals.
* To make situation clear, I'm reading the articles on general signature-based
  algorithms (such as Eder's papers ([1][Anal], [2][Sig]) and [G2V][G2V])

Papers
------
[Improving incremental signature-based Gröbner basis algorithms][Sig]
:    Paper on the improvements for signature-based algorithms.
[A New Incremental Algorithm for Computing Groebner Bases][G2V]
:    The signature-based algorithm for general ideals (called G2V algorithm).
[On the Criteria of the F5 Algorithm][Eder]
:    Paper on correctness of Rewritten criteria and involves implementation in SINGULAR.
[Faugère's F5 Algorithm][Perry]
:    Pseudocode of F5 by co-implementor of SINGULAR implementation presented in [Eder][Eder]'s paper.
[An analysis of inhomogeneous signature-based Gröbner basis computations][Anal]
:    Paper on signature-based Gröbner basis computation algorithms.
[A new efﬁcient algorithm for computing Gröbner bases without reduction to zero (F5)](http://www.risc.jku.at/Groebner-Bases-Bibliography/gbbib_files/publication_502.pdf)
:    Original paper. This includes some errors and have an issue on the proof of termination.
[Faugère's F5 Algorithm Revisited][Rev]
:    More accurate and comprehensive description on F_5 algorithm. This paper notes on termination, but doesn't guarantee termination for general inputs.
[F5C: a variant of Faugère’s F5 algorithm with reduced Gröbner bases][F5C]
:    Improved version of F5 algorithm, which computes reduced bases in internal computation. This algorithm is not proven to be terminate for general input cases.
[Faugère's F5 algorithm: variants and termination issues](http://www.mathematik.uni-kl.de/~ederc/download/cased_talk.pdf)
:    A short slide on F5 algorithm. This discusses on improvements and how to make F5 algorithm to terminate for general cases.
[Modifying Faugère's F5 Algorithm to Ensure Termination][Term]
:    This paper discusses several ways to make F5 algorithm terminate for not only regular sequences but also general cases.

[Rev]: https://eprint.iacr.org/2006/404.pdf

[F5C]: http://arxiv.org/pdf/0906.2967.pdf

[Term]: http://arxiv.org/pdf/1006.0318v4.pdf

[Orig]: http://www.risc.jku.at/Groebner-Bases-Bibliography/gbbib_files/publication_502.pdf

[Anal]: http://arxiv.org/pdf/1203.6186.pdf

[Eder]: http://arxiv.org/pdf/0804.2033v4.pdf

[Perry]: http://www.math.usm.edu/perry/Research/CorrectAlgorithm.pdf

[Sig]: http://arxiv.org/abs/1201.6472

[G2V]: http://www.math.clemson.edu/~sgao/papers/GGV10.pdf

F_4 algorithm
=============
A naive implementation has been done before GSoC starts.
As we have to implement more efficient matrix triangulation, I'll read the following papers:

[A new efficient algorithm for computing Groebner basis F4][F4Orig]
:    Original paper. Current implementation is based on this paper.
[An Implementation of Faugèere's F4 Algorithm for Computing Gröbner Bases][Cabarcas]
:    Paper on the detail of the implementation of F4. Maybe informative for matrix triangulation methods.

[F4Orig]: http://www-polsys.lip6.fr/~jcf/Papers/F99a.pdf

[Cabarcas]: https://etd.ohiolink.edu/ap/10?0::NO:10:P10_ACCESSION_NUM:ucin1277120935#abstract-files

### structured Gaussian Elimination

[Cabarcas][Cabarcas]'s paper suggests that it'd be better to use the simplified version of structured Gaussian Elimination but not describe the detail of its algorithm (for example, how to determine columns "light" or "heavy").

Here is some references which might be useful:

* [Solving Large Sparse Linear Systems Over Finite Fields][Solving]
* [An Approximate Probabilistic Model for Structured Gaussian Elimination][Approx]

[Solving]: http://www.farcaster.com/papers/crypto-solve/node5.html

[Approx]: http://algo.inria.fr/seminars/sem98-99/bender1.html#LaOd90a



Find state of the art algorithms for maximum weighted satisfiability problems based on local search. Consider papers from the past few years from the theory and Applications of Satisfiability conference and the SAT competition.

Searched the web, read a memory

Here's the current landscape, which is dominated by one lineage of clause-weighting SLS solvers plus a standard hybridization trick.

**The main line (weighted partial MaxSAT, WPMS)**

Each of these is an SLS solver whose novelty is the clause-weighting scheme; each beat the previous one and won the MaxSAT Evaluation anytime tracks:

- **SATLike3.0** (Cai & Lei, *AIF* 2020) — the base framework everything else forks from; runner-up in the weighted anytime tracks of MSE 2020/2021.
- **NuWLS** (Chu, Cai, Luo, AAAI 2023) — soft-clause weight initialization plus separate update conditions for hard and soft clauses; the hybrid NuWLS-c won all four incomplete categories at MSE 2022, and NuWLS-c-2023 repeated in 2023. [AAAI](https://ojs.aaai.org/index.php/AAAI/article/view/25505)[AAAI](https://ojs.aaai.org/index.php/AAAI/article/view/25505)
- **USW-LS** (Chu, Li, Ye, Cai, **SAT 2024**, LIPIcs 305:8) — the one squarely in the SAT-conference venue you asked about. Its Unified-SW scheme raises the weights of *all* soft clauses at feasible local optima, satisfied or not, while preserving their hierarchy.
- **SPB-MaxSAT** (Zheng, Chen, Li, He, IJCAI 2024) — imports the soft-conflict pseudo-Boolean constraint idea from exact solvers into the local-search weighting system, with an adaptive (non-constant) weight adjustment. Champion of all anytime tracks at MSE 2024. [Semantic Scholar](https://www.semanticscholar.org/paper/NuWLS:-Improving-Local-Search-for-(Weighted)-MaxSAT-Chu-Cai/68d54d627cfaa914d277a3f4a5508de1c4abe4ef)
- **DeepDist** (Jiang et al., arXiv 2512.05619, Dec 2025) — newest. First scheme to use *different* update conditions for PMS vs. WPMS soft clauses, and to zero out hard-clause initial weights once a feasible solution exists. Reports beating both MSE 2024 winners. Code: github.com/jmhmaxsat/DeepDist.

**Orthogonal boosters** (composable with any of the above)

- **BandMaxSAT / BandHS** (IJCAI 2022; *AIJ* 338:104242, 2025) — multi-armed bandit models over soft clauses and over literals in hard clauses to pick escape directions at local optima. [ScienceDirect](https://www.sciencedirect.com/science/article/abs/pii/S0004370224001784)
- **FPS** (farsighted probabilistic sampling, AAAI 2023) — lookahead sampling; combined with BandMaxSAT in the MSE 2024 weighted winner.
- **Initialization/decimation**: DeciLS (IJCAI 2017), InitPMS (*SCIS* 68:122101, 2025), and DeepDist's UnH-Decimation.

**The thing that actually wins competitions.** No pure SLS solver wins the weighted anytime track. Every recent winner is an SLS front-end hybridized with the SAT-based anytime solver TT-Open-WBO-Inc (Nadel) — it has been a component of the MSE 2023 and 2024 winners in all four anytime categories. If you're benchmarking, the SLS component alone is not the right comparison point. See also **SLS-Enhanced Core-Boosted Linear Search** (CP 2025, LIPIcs 31:28) from the Helsinki group for the reverse hybridization. [GitHub](https://github.com/alexander-nadel-academic/tt-open-wbo-inc/)

**One methodological caveat.** Anytime-performance analysis of SATLike3.0, BandMaxSAT, NuWLS, and MaxFPS shows their rankings flip depending on the time budget — NuWLS leads in aggregate but not at short budgets, while BandMaxSAT overtakes after ~100s. Fixed-budget MSE scores at 60s/300s hide this. [arXiv](https://arxiv.org/html/2403.06568v1)

I couldn't retrieve MSE 2025 rankings — the results pages aren't indexed and the 2025 site returned empty for me. Worth checking maxsat-evaluations.github.io/2025 directly, since that would tell you whether DeepDist-style ideas or something new took the weighted track.

I want to solve problems that have hundreds of weighted unary clauses together with thousands of hard clauses. Weights are positive integers. What systems should I consider first?

Added to memory

At that size, start with **exact** solvers, not local search. Hundreds of soft units and thousands of hard clauses is a small instance by MaxSAT Evaluation standards, and the anytime/SLS machinery from my last answer exists for instances where proving optimality is hopeless. You may well get proven optima in seconds.

Two structural facts work in your favor:

- **Soft unit clauses are the ideal shape for core-guided solving.** No relaxation variables are needed — each soft unit already *is* its own indicator. Core-guided and implicit-hitting-set solvers operate directly on a few hundred assumption literals, which is a tiny search space for them.
- **Your objective is a plain linear function** over the original variables, so an ILP encoding is direct and lossless.

**What to try, in order**

1. **RC2** via PySAT — for prototyping. Pure Python API, you'll have an answer in ten minutes and it's a genuinely strong core-guided solver.
2. **EvalMaxSAT** and **UWrMaxSat-SCIP** — two of the top three in the weighted exact category of MSE 2024, alongside CASHWMaxSAT-DisjCom-S6. UWrMaxSat runs a portfolio with SCIP; EvalMaxSAT is clean and fast to build. [arxiv](https://arxiv.org/pdf/2506.06216)
3. **CASHWMaxSAT** (Zhu et al., IJCAI 2025) — core-guided with extended stratification that progressively focuses on high-weight soft clauses, plus disjoint core minimization. Stratification matters specifically if your weights span orders of magnitude. [IJCAI](https://www.ijcai.org/proceedings/2025/295)
4. **CP-SAT (OR-Tools)** or **Gurobi** — worth one experiment given the direct linear objective. On structured industrial instances these sometimes crush the MaxSAT solvers, and CP-SAT gives you a modeling layer instead of raw WCNF.

**Practical notes**

- Run **MaxPre 2** as a preprocessor. It's cheap and often decisive on instances with many hard clauses.
- If your weights have big gaps (one weight exceeding the sum of all smaller ones), you have BMO structure — say so to the solver, since stratification exploits it.
- If you'll solve many near-identical instances (changing weights, adding constraints), look at **IPAMIR**, the incremental MaxSAT interface, rather than restarting cold.
- Use the current WCNF format: hard clauses prefixed `h`, no `p` line.

Only fall back to the anytime solvers — NuWLS-c, SPB-MaxSAT-c, Loandra — if exact solving stalls. And "thousands of hard clauses" says little about difficulty on its own; a few hundred hard clauses encoding the wrong thing can be worse than a million easy ones. If you hit a wall, the structure of the hard part is where to look.

I am currently using TT-Open-WBO-Inc for maxsat. How does it compare with the solvers you recommend?

Thought for 19s

You're using a strong solver, but it's built for a different job than the ones I listed — and that difference matters for your instance size.

**It's an anytime solver, not an exact one.** TT-Open-WBO-Inc gives you the best solution it found by the time you stopped it; it doesn't hand you a proof that no better assignment exists. In MSE 2024 it competed only in the anytime track. EvalMaxSAT, UWrMaxSat, CASHWMaxSAT, and RC2 terminate with "this is the optimum." With a few hundred soft units, that proof is probably within reach — and if it is, you've been leaving certainty on the table without knowing it. [Maxsat-evaluations](https://maxsat-evaluations.github.io/2024/mse24-talk.pdf)

**It's also half of what the competition winners actually run.** TT-Open-WBO-Inc has been a component of the MSE 2023 and 2024 anytime winners in all four categories — but as the SAT-based half, paired with an SLS front end (NuWLS, then SPB-MaxSAT). Running it alone is running the winner with a piece missing. [GitHub](https://github.com/alexander-nadel-academic/tt-open-wbo-inc/)

**Its weighted mode may already suit your weights.** TT-Open-WBO-Inc combines several strategies: SATLike for inprocessing, a modified Mrs. Beaver for unweighted instances, BMO-clustering for weighted ones, and Polosat, a SAT-based local search. Nadel found the Polosat-OBV variant better for weighted solving specifically. That BMO-clustering is doing weight stratification — the same structure CASHWMaxSAT's extended stratification exploits, so if it's been working well for you, that's a hint your weights have exploitable strata. [arXiv](https://arxiv.org/html/2306.07635)[SAGE Publications](https://journals.sagepub.com/doi/10.3233/SAT-231504)

**What I'd actually do**

Don't replace it — race it. Run EvalMaxSAT or UWrMaxSat-SCIP on the same instances with a generous timeout and compare against TT-Open-WBO-Inc's best cost. Three outcomes:

- The exact solver proves optimality and the costs match — you were already optimal, and now you know. Switch for the certificate.
- It proves a strictly better optimum — you've been accepting a gap.
- It times out — TT-Open-WBO-Inc is the right tool, and the upgrade path is a hybrid: NuWLS-c or SPB-MaxSAT-c, both of which have your current solver inside them.

Worth adding MaxPre 2 in front regardless; it helps both families.



MaxPre 2 is on Bitbucket, not GitHub:

**https://bitbucket.org/coreo-group/maxpre2/src/master/**

It's maintained by Hannes Ihalainen in the Helsinki CoReO group, and adds quality-of-life improvements and extended reasoning techniques over version 1, along with support for multi-objective MaxSAT instances. [Jeremiasberg](https://jeremiasberg.com/software/maxpre/)

Two things worth knowing since you'll likely hit them:

- The original MaxPre (Korhonen et al., SAT 2017) is at github.com/Laakeri/maxpre. Plenty of build instructions and solver READMEs still point there — UWrMaxSat's build instructions, for instance, tell you to clone the Laakeri repo and compile it as a static library. If you're following someone's setup guide, check which version it assumes. [GitHub](https://github.com/marekpiotrow/UWrMaxSat/blob/master/README.md)
- MaxPre has both a standalone mode and an API for integration into a solver. For your case, standalone is the easier start: preprocess the WCNF, run the solver, then reconstruct the solution back to the original variables. Don't skip reconstruction — the preprocessed instance's model isn't directly meaningful in your original variable space.
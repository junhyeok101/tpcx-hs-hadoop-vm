"""Milestone 3 figures for the README / RESULTS.md (static PNG, light surface).

Values are the medians reported in workload/RESULTS.md. Stacked bars show the
per-phase medians from the job logs (setup / map / tail) and are labelled with
their sum; wall-clock medians, 1-2 s higher, are in the RESULTS.md tables.
"""
import sys
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

OUT = sys.argv[1] if len(sys.argv) > 1 else "."

SURFACE = "#fcfcfb"
INK = "#2b2b29"
MUTED = "#898781"
GRID = "#e1e0d9"
C1, C2, C3 = "#2a78d6", "#eb6834", "#1baf7a"   # validated categorical slots 1-3

plt.rcParams.update({
    "figure.facecolor": SURFACE, "axes.facecolor": SURFACE, "savefig.facecolor": SURFACE,
    "font.family": "DejaVu Sans", "font.size": 10, "text.color": INK,
    "axes.edgecolor": GRID, "axes.labelcolor": MUTED, "xtick.color": MUTED, "ytick.color": MUTED,
    "axes.spines.top": False, "axes.spines.right": False, "axes.spines.left": False,
    "axes.grid": True, "axes.grid.axis": "y", "grid.color": GRID, "grid.linewidth": 0.8,
    "axes.axisbelow": True, "legend.frameon": False,
})


def stacked(fname, labels, setup, mapp, tail, wall, title, xlabel, best):
    fig, ax = plt.subplots(figsize=(7.2, 3.8), dpi=200)
    x = range(len(labels))
    kw = dict(width=0.56, edgecolor=SURFACE, linewidth=1.5)
    ax.bar(x, setup, color=C1, label="setup (sampling + submit)", **kw)
    ax.bar(x, mapp, bottom=setup, color=C2, label="map phase", **kw)
    b2 = [s + m for s, m in zip(setup, mapp)]
    ax.bar(x, tail, bottom=b2, color=C3, label="tail (shuffle + reduce after maps)", **kw)
    tops = [b + t for b, t in zip(b2, tail)]
    best = tops.index(min(tops))           # bold the shortest bar
    for i, w in enumerate(wall):
        top = tops[i]
        ax.text(i, top + 1.5, f"{top:.1f} s", ha="center", va="bottom", fontsize=9,
                color=INK, fontweight="bold" if i == best else "normal")
    ax.set_xticks(list(x), labels)
    ax.set_xlabel(xlabel)
    ax.set_ylabel("seconds")
    ax.set_ylim(0, max(b + t for b, t in zip(b2, tail)) * 1.18)
    ax.set_title(title, loc="left", fontsize=11, color=INK, pad=28)
    ax.legend(loc="lower left", bbox_to_anchor=(0, 1.0), ncol=3, fontsize=8.5,
              handlelength=1.2, columnspacing=1.2, borderaxespad=0.2)
    fig.tight_layout()
    fig.savefig(f"{OUT}/{fname}")
    plt.close(fig)


def lines(fname, xs, xlabels, measured, ideal, title, xlabel, ylabel, mlabel, ilabel, fmt,
          off=(10, -14), ha="left"):
    fig, ax = plt.subplots(figsize=(7.2, 3.8), dpi=200)
    x = list(xs)   # numeric positions, so a straight line means proportional
    ax.plot(x, ideal, color=MUTED, linewidth=2, linestyle=(0, (4, 3)), label=ilabel)
    ax.plot(x, measured, color=C1, linewidth=2, marker="o", markersize=7,
            markeredgecolor=SURFACE, markeredgewidth=2, label=mlabel)
    for i, v in enumerate(measured):
        ax.annotate(fmt(v), (x[i], v), textcoords="offset points", xytext=off,
                    ha=ha, fontsize=9, color=INK)
    ax.set_xticks(x, xlabels)
    ax.set_xlim(0, x[-1] * 1.12)
    ax.set_xlabel(xlabel)
    ax.set_ylabel(ylabel)
    ax.set_ylim(0, max(max(measured), max(ideal)) * 1.15)
    ax.set_title(title, loc="left", fontsize=11, color=INK, pad=22)
    ax.legend(loc="lower left", bbox_to_anchor=(0, 1.0), ncol=2, fontsize=8.5,
              handlelength=2.2, borderaxespad=0.2)
    fig.tight_layout()
    fig.savefig(f"{OUT}/{fname}")
    plt.close(fig)


# Experiment 1 -- reducers 1..7 (8 maps, 1 GB)
stacked("m3-reducers.png",
        [f"{r}" for r in range(1, 8)],
        setup=[4.7, 4.8, 4.8, 5.1, 4.7, 5.3, 4.7],
        mapp=[39.6, 37.7, 36.7, 37.6, 34.6, 35.6, 36.7],
        tail=[22.2, 18.2, 15.2, 26.3, 23.2, 23.3, 26.3],
        wall=[68.8, 63.6, 59.0, 70.5, 64.5, 65.4, 69.3],
        title="HSSort phases by number of reducers - 1 GB, 8 maps, median of 3",
        xlabel="reducers (at most 3 run at once in the 3840 MB pool)", best=2)

# Experiment 2 -- maps 4 / 8 / 16 (3 reducers, 1 GB)
stacked("m3-maps.png",
        ["4 (250 MB splits)", "8 (128 MB)", "16 (64 MB)"],
        setup=[4.6, 4.6, 4.6],
        mapp=[32.5, 35.6, 56.8],
        tail=[19.2, 15.2, 14.2],
        wall=[56.9, 58.1, 76.3],
        title="HSSort phases by number of maps - 1 GB, 3 reducers, median of 3",
        xlabel="maps (at most 4 run at once)", best=0)

# Experiment 3 -- data size
lines("m3-scale-data.png", [1, 2, 4, 8], ["1 GB", "2 GB", "4 GB", "8 GB"],
      measured=[56.0, 93.4, 186.1, 354.3],
      ideal=[56.0, 112.0, 224.0, 448.0],
      title="HSSort vs data size - 3 reducers, 3840 MB pool, median of 3",
      xlabel="dataset size", ylabel="seconds",
      mlabel="measured", ilabel="linear from 1 GB", fmt=lambda v: f"{v:.1f} s")

# Experiment 4 -- resources
lines("m3-scale-resources.png", [0.5, 1, 2], ["0.5x\n1920 MB", "1x\n3840 MB", "2x\n7680 MB"],
      measured=[1.00, 2.40, 3.22],
      ideal=[1, 2, 4],
      title="HSSort speed-up vs YARN pool - 2 GB, reducers = reducer slots",
      xlabel="YARN NodeManager pool", ylabel="speed-up vs 0.5x",
      mlabel="measured", ilabel="ideal (proportional)", fmt=lambda v: f"{v:.2f}x",
      off=(-9, 7), ha="right")
print("ok")

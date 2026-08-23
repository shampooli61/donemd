import { describe, it, expect } from 'vitest';
import { computeFoldRanges } from './heading-fold';
import type { FoldBlock } from './heading-fold';

// computeFoldRanges works on a flat list of top-level blocks (the discipline
// mirrors heading-extractor.test.ts: pure function, hand-built input, assert
// the array). `h(level)` is a heading block; `p()` is any non-heading block.

function h(level: number): FoldBlock {
  return { isHeading: true, level };
}
function p(): FoldBlock {
  return { isHeading: false, level: 0 };
}

describe('computeFoldRanges', () => {
  it('test_section_runs_to_next_same_level_heading', () => {
    // H2, body, H2 → first H2 folds only its own body, stops at the second H2.
    const ranges = computeFoldRanges([h(2), p(), p(), h(2), p()]);
    expect(ranges).toEqual([
      { ordinal: 0, headingBlock: 0, startBlock: 1, endBlock: 3 },
      { ordinal: 1, headingBlock: 3, startBlock: 4, endBlock: 5 },
    ]);
  });

  it('test_higher_level_heading_absorbs_nested_lower_ones', () => {
    // H1 folds everything down to the next H1, INCLUDING the nested H2/H3.
    // blocks:  H1  p   H2  p   H3  p   H1
    // index:   0   1   2   3   4   5   6
    const ranges = computeFoldRanges([h(1), p(), h(2), p(), h(3), p(), h(1)]);
    // H1 @0 → [1,6): swallows the H2 and H3 sections.
    expect(ranges[0]).toEqual({ ordinal: 0, headingBlock: 0, startBlock: 1, endBlock: 6 });
    // H2 @2 → [3,4): stops at the H3 (lower level does NOT stop it) — wait,
    // H3 has level 3 > 2, so it does NOT terminate H2; H2 runs to the H1 @6.
    expect(ranges[1]).toEqual({ ordinal: 1, headingBlock: 2, startBlock: 3, endBlock: 6 });
    // H3 @4 → [5,6): stops at the H1 @6.
    expect(ranges[2]).toEqual({ ordinal: 2, headingBlock: 4, startBlock: 5, endBlock: 6 });
    // H1 @6 → [7,7): last block, empty section.
    expect(ranges[3]).toEqual({ ordinal: 3, headingBlock: 6, startBlock: 7, endBlock: 7 });
  });

  it('test_trailing_heading_has_empty_range', () => {
    // A heading with nothing after it: startBlock === endBlock ⇒ not foldable.
    const ranges = computeFoldRanges([p(), h(2)]);
    expect(ranges).toEqual([{ ordinal: 0, headingBlock: 1, startBlock: 2, endBlock: 2 }]);
    expect(ranges[0].startBlock).toBe(ranges[0].endBlock);
  });

  it('test_adjacent_headings_have_empty_ranges', () => {
    // H2 immediately followed by another H2 → first folds nothing.
    const ranges = computeFoldRanges([h(2), h(2), p()]);
    expect(ranges[0]).toEqual({ ordinal: 0, headingBlock: 0, startBlock: 1, endBlock: 1 });
    expect(ranges[1]).toEqual({ ordinal: 1, headingBlock: 1, startBlock: 2, endBlock: 3 });
  });

  it('test_no_headings_returns_empty', () => {
    expect(computeFoldRanges([p(), p(), p()])).toEqual([]);
    expect(computeFoldRanges([])).toEqual([]);
  });

  it('test_ordinals_count_only_headings_in_document_order', () => {
    // Ordinals are 0,1,2 for the three headings regardless of interleaved prose.
    const ranges = computeFoldRanges([p(), h(1), p(), h(2), p(), h(2)]);
    expect(ranges.map((r) => r.ordinal)).toEqual([0, 1, 2]);
    expect(ranges.map((r) => r.headingBlock)).toEqual([1, 3, 5]);
  });

  it('test_lower_then_higher_level_sequence', () => {
    // H3, body, H1 → the H3 section stops at the higher-level H1.
    const ranges = computeFoldRanges([h(3), p(), h(1), p()]);
    expect(ranges[0]).toEqual({ ordinal: 0, headingBlock: 0, startBlock: 1, endBlock: 2 });
    expect(ranges[1]).toEqual({ ordinal: 1, headingBlock: 2, startBlock: 3, endBlock: 4 });
  });
});

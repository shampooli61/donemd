import { describe, it, expect } from 'vitest';
import { extractHeadings } from './heading-extractor';

// Test names mirror the user stories they cover (story 26/27/30 + the AC
// edge cases: multi-level order, no-heading, empty, inline formatting,
// duplicate text, callout-nested). Same convention as the Swift suites.

/** Build a heading node with plain text content. */
function heading(level: number, text: string) {
  return {
    type: 'heading',
    attrs: { level },
    content: [{ type: 'text', text }],
  };
}

function paragraph(text: string) {
  return { type: 'paragraph', content: [{ type: 'text', text }] };
}

function doc(...content: object[]) {
  return { type: 'doc', content };
}

describe('extractHeadings', () => {
  it('test_returns_nested_levels_in_document_order', () => {
    const result = extractHeadings(
      doc(
        heading(1, 'Title'),
        paragraph('intro'),
        heading(2, 'Section A'),
        heading(3, 'Sub A1'),
        heading(2, 'Section B'),
      ),
    );
    expect(result.map((h) => [h.level, h.text])).toEqual([
      [1, 'Title'],
      [2, 'Section A'],
      [3, 'Sub A1'],
      [2, 'Section B'],
    ]);
    // Index follows document order, 0-based.
    expect(result.map((h) => h.index)).toEqual([0, 1, 2, 3]);
  });

  it('test_document_with_no_headings_returns_empty', () => {
    const result = extractHeadings(
      doc(paragraph('just some text'), paragraph('and more')),
    );
    expect(result).toEqual([]);
  });

  it('test_empty_document_returns_empty', () => {
    expect(extractHeadings(doc())).toEqual([]);
    expect(extractHeadings({ type: 'doc' })).toEqual([]);
  });

  it('test_heading_with_inline_formatting_yields_plain_text', () => {
    const h = {
      type: 'heading',
      attrs: { level: 2 },
      content: [
        { type: 'text', text: 'Bold', marks: [{ type: 'bold' }] },
        { type: 'text', text: ' and ' },
        {
          type: 'text',
          text: 'link',
          marks: [{ type: 'link', attrs: { href: 'https://x' } }],
        },
      ],
    };
    const result = extractHeadings(doc(h));
    expect(result).toHaveLength(1);
    expect(result[0].text).toBe('Bold and link');
    expect(result[0].level).toBe(2);
  });

  it('test_duplicate_heading_text_gets_unique_ids', () => {
    const result = extractHeadings(
      doc(heading(2, 'Notes'), heading(2, 'Notes'), heading(2, 'Notes')),
    );
    expect(result.map((h) => h.text)).toEqual(['Notes', 'Notes', 'Notes']);
    const ids = result.map((h) => h.id);
    expect(new Set(ids).size).toBe(3);
    expect(ids).toEqual(['0', '1', '2']);
  });

  it('test_heading_nested_inside_callout_is_collected', () => {
    // callout.ts allows heading content, so the extractor must recurse
    // into block containers, not just scan top-level children.
    const callout = {
      type: 'callout',
      attrs: { type: 'note' },
      content: [heading(3, 'Inside callout'), paragraph('body')],
    };
    const result = extractHeadings(
      doc(heading(1, 'Top'), callout, heading(1, 'After')),
    );
    expect(result.map((h) => [h.level, h.text])).toEqual([
      [1, 'Top'],
      [3, 'Inside callout'],
      [1, 'After'],
    ]);
  });

  it('test_non_object_input_returns_empty', () => {
    expect(extractHeadings(null)).toEqual([]);
    expect(extractHeadings(undefined)).toEqual([]);
    expect(extractHeadings('string')).toEqual([]);
  });

  it('test_heading_missing_level_defaults_to_one', () => {
    const result = extractHeadings(
      doc({ type: 'heading', content: [{ type: 'text', text: 'No level' }] }),
    );
    expect(result[0].level).toBe(1);
    expect(result[0].text).toBe('No level');
  });
});

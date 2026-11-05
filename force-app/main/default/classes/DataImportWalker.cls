/**********************************************************************************
* Name         : DataImportWalker
* Author       : Dalton Wilt
* Desc         : Turns one chunk's rows into records, according to the template's
*                sections.
*
*                Stateless and chunk-local by design. It is handed the rows it can see
*                and the row number they start at, and it never needs to know what came
*                before - which is what lets Batch Apex process chunks in whatever order
*                it likes.
*
*                That only works because the two questions a chunk cannot answer on its
*                own were answered earlier: which section a row belongs to (resolved by
*                the uploader while it sliced the file, and stored on the job) and
*                whether a key is duplicated within the file (likewise). See
*                DataImportJob.
* Created On   : 2026-08-03
* Test classes : DataImportWalkerTest
*
* Sharing      : inherited sharing - builds records in memory and writes nothing;
*                DataImportBatch does the DML in the caller's context.
*
* @see DataImportSpec
* @see DataImportBatch
*
* Modification Log:
* ----------------------------------------------------------------------
* Developer        Date          Description
* ----------------------------------------------------------------------
* Dalton Wilt      2026-08-03    Initial implementation.
**********************************************************************************/

public inherited sharing class DataImportWalker {
  /** One data row, built but not yet written. */
  public class Row {
    /** The record, with columns, defaults and bindings applied. Null when the row could not be built. */
    public SObject record;

    /** One-based row number in the ORIGINAL file — what every message refers to. */
    public Integer rowNumber;

    /** Which template section produced it, for per-section reject files. */
    public String section;

    /** The row re-encoded as CSV, so a failed row can be handed back in a re-uploadable file. */
    public String raw;

    /** Value of the match column, when the section has one. */
    public String key;

    /** Set when a cell would not coerce; the row is reported and never written. */
    public Boolean failed = false;
  }

  /** What one walk produced: every row it built, and every cell it could not read. */
  public class Outcome {
    /** Every data row in the chunk, failed ones included - a failed row still has to
     *  reach the reject file. */
    public List<Row> rows = new List<Row>();

    /** One message per unreadable cell, already carrying its row and column. */
    public List<String> errors = new List<String>();

    /** Rows that produced a usable record. */
    public List<Row> usable() {
      List<Row> ok = new List<Row>();
      for (Row row : rows) {
        if (!row.failed && row.record != null) {
          ok.add(row);
        }
      }
      return ok;
    }
  }

  /**
   * Where each section's rows live in the file, resolved before the batch started.
   *
   * `lastRow` null means the section runs to the end of the file.
   */
  public class SectionRange {
    /** Which section of the template these rows belong to; '' or null for a
     *  template with a single unnamed table. */
    public String sectionName;

    /** One-based first data row in the original file. */
    public Integer firstRow;

    /** One-based last data row, or null when the section runs to the end of file. */
    public Integer lastRow;

    /**
     * @param rowNumber a one-based row number in the original file
     * @return          whether this section claims that row; an open-ended range
     *                  (null lastRow) runs to the end of the file
     */
    public Boolean covers(Integer rowNumber) {
      if (firstRow != null && rowNumber < firstRow) {
        return false;
      }
      return lastRow == null || rowNumber <= lastRow;
    }
  }

  private final DataImportSpec spec;
  private final List<SectionRange> ranges;
  private final Map<String, Object> bindings;
  private final Map<String, DataImport.Coercer> coercers = new Map<String, DataImport.Coercer>();

  /**
   * @param spec     the template
   * @param ranges   resolved row ranges per section; empty falls back to the section's own geometry
   * @param bindings runtime values for `$placeholder` defaults, including any resolved cells section
   */
  public DataImportWalker(
    DataImportSpec spec,
    List<SectionRange> ranges,
    Map<String, Object> bindings
  ) {
    this.spec = spec;
    this.ranges = ranges == null ? new List<SectionRange>() : ranges;
    this.bindings = bindings == null ? new Map<String, Object>() : bindings;
  }

  /**
   * @param rows            this chunk's parsed rows
   * @param firstRowNumber  one-based file row number of rows[0]
   */
  public Outcome walk(List<List<String>> rows, Integer firstRowNumber) {
    Outcome outcome = new Outcome();

    for (Integer offset = 0; offset < rows.size(); offset++) {
      Integer rowNumber = firstRowNumber + offset;
      DataImportSpec.Section section = sectionFor(rowNumber);
      if (section == null) {
        continue; // header, a gap between tables, or a row no section claims
      }
      List<String> cells = rows[offset];
      if (DataImport.isRowBlank(cells, section.columnIndexes())) {
        continue;
      }

      Row row = new Row();
      row.rowNumber = rowNumber;
      row.section = section.sectionName;
      row.raw = encode(cells);

      List<String> problems = new List<String>();
      row.record = build(section, cells, rowNumber, problems);
      row.key = keyOf(section, cells);

      if (
        section.matchOn != null &&
        String.isBlank(row.key) &&
        section.matchOn.isKeyRequired()
      ) {
        problems.add(
          'Row ' +
            rowNumber +
            ', column ' +
            section.matchOn.column +
            ': a value is required to match an existing record.'
        );
      }

      if (!problems.isEmpty()) {
        row.failed = true;
        outcome.errors.addAll(problems);
      }
      outcome.rows.add(row);
    }
    return outcome;
  }

  // ------------------------------------------------------------------
  // Building
  // ------------------------------------------------------------------

  private SObject build(
    DataImportSpec.Section section,
    List<String> cells,
    Integer rowNumber,
    List<String> problems
  ) {
    SObject record = Schema.getGlobalDescribe()
      .get(section.target)
      .newSObject();

    // Defaults first, so a column of the same name wins over a template-wide value.
    if (section.defaults != null) {
      for (String apiName : section.defaults.keySet()) {
        Object value = resolve(section.defaults.get(apiName));
        if (value != null) {
          record.put(apiName, value);
        }
      }
    }

    DataImport.Coercer coercer = coercerFor(section.target);
    for (String letter : section.columns.keySet()) {
      Integer index = DataImportSpec.columnIndex(letter);
      if (index == null) {
        continue;
      }
      coercer.assign(
        record,
        section.columns.get(letter),
        DataImport.cell(cells, index),
        'Row ' + rowNumber + ', column ' + letter,
        problems
      );
    }
    applyGroups(section, record, cells, coercer, rowNumber, problems);
    return record;
  }

  /**
   * Fold this row's Yes/No columns into their multi-select fields.
   *
   * Collected before anything is written because several columns feed one field — writing per
   * column would leave only the last option set.
   *
   * The configured option is checked against the field's own values on the way through. It is the
   * template author who gets that wrong, not the recipient, but the cost lands on the recipient:
   * the value is written verbatim, so on a restricted picklist the platform refuses the insert and
   * an all-or-nothing job hands the whole file back over one bad string in the config. Naming the
   * column and the field here is what turns that into something readable.
   */
  private void applyGroups(
    DataImportSpec.Section section,
    SObject record,
    List<String> cells,
    DataImport.Coercer coercer,
    Integer rowNumber,
    List<String> problems
  ) {
    if (section.groups == null) {
      return;
    }
    for (DataImportSpec.Grouping grouping : section.groups) {
      if (grouping.options == null) {
        continue;
      }
      Set<String> allowed = coercer.allowedValues(grouping.field);
      List<String> selected = new List<String>();
      for (String letter : grouping.options.keySet()) {
        Integer index = DataImportSpec.columnIndex(letter);
        if (
          index == null || !DataImport.isYes(DataImport.cell(cells, index))
        ) {
          continue;
        }
        String option = grouping.options.get(letter);
        if (!allowed.isEmpty() && !allowed.contains(option)) {
          problems.add(
            'Row ' +
              rowNumber +
              ', column ' +
              letter +
              ': "' +
              option +
              '" is not one of the values ' +
              grouping.field +
              ' accepts. The template needs correcting — this is not something the file can fix.'
          );
          continue;
        }
        selected.add(option);
      }
      if (!selected.isEmpty()) {
        record.put(grouping.field, String.join(selected, ';'));
      }
    }
  }

  /** `$name` resolves against the bindings; anything else is a literal. */
  private Object resolve(String reference) {
    if (String.isBlank(reference)) {
      return null;
    }
    return reference.startsWith('$')
      ? bindings.get(reference.substring(1))
      : reference;
  }

  private String keyOf(DataImportSpec.Section section, List<String> cells) {
    if (section.matchOn == null) {
      return null;
    }
    Integer index = DataImportSpec.columnIndex(section.matchOn.column);
    return index == null ? null : DataImport.cell(cells, index);
  }

  /** One describe pass per target object per chunk, never per cell. */
  private DataImport.Coercer coercerFor(String target) {
    if (!coercers.containsKey(target)) {
      coercers.put(
        target,
        new DataImport.Coercer(Schema.getGlobalDescribe().get(target))
      );
    }
    return coercers.get(target);
  }

  // ------------------------------------------------------------------
  // Section resolution
  // ------------------------------------------------------------------

  /**
   * The section a row belongs to.
   *
   * Prefers the ranges resolved by the uploader, because a table whose length is not known until
   * the file is read cannot be located from the template alone. Falls back to the section's own
   * firstDataRow / lastDataRow, which is enough for a template with one table at a fixed offset.
   */
  @TestVisible
  private DataImportSpec.Section sectionFor(Integer rowNumber) {
    for (SectionRange range : ranges) {
      if (!range.covers(rowNumber)) {
        continue;
      }
      // A template with one table needs no sectionName, so the uploader sends '' for it. Matching
      // that against a null name finds nothing and silently skips every row — which is what it did.
      DataImportSpec.Section named = String.isBlank(range.sectionName)
        ? soleRowSection()
        : spec.sectionNamed(range.sectionName);
      if (named != null) {
        return named;
      }
    }
    if (!ranges.isEmpty()) {
      return null; // ranges were supplied and none claims this row
    }
    for (DataImportSpec.Section section : spec.rowSections()) {
      Boolean afterStart =
        section.firstDataRow != null &&
        rowNumber >= section.firstDataRow;
      Boolean beforeEnd =
        section.lastDataRow == null ||
        rowNumber <= section.lastDataRow;
      if (afterStart && beforeEnd) {
        return section;
      }
    }
    return null;
  }

  /** The only rows section, for a template that never needed to name it. */
  private DataImportSpec.Section soleRowSection() {
    List<DataImportSpec.Section> rows = spec.rowSections();
    return rows.isEmpty() ? null : rows[0];
  }

  // ------------------------------------------------------------------
  // CSV re-encoding
  // ------------------------------------------------------------------

  /**
   * Cells back to a CSV line, so a failed row can be written into a file the user re-uploads.
   *
   * Re-encoded rather than carrying the original text through: the parser joins a record that
   * spanned several physical lines, so there is no single original line to keep. Re-encoding is
   * round-trip safe, which is what actually matters.
   */
  public static String encode(List<String> cells) {
    List<String> encoded = new List<String>();
    for (String cell : cells) {
      encoded.add(quote(cell));
    }
    return String.join(encoded, ',');
  }

  /** Quotes only when the value would otherwise break the line. */
  public static String quote(String value) {
    if (value == null) {
      return '';
    }
    if (
      value.contains(',') ||
      value.contains('"') ||
      value.contains('\n') ||
      value.contains('\r')
    ) {
      return '"' + value.replace('"', '""') + '"';
    }
    return value;
  }
}
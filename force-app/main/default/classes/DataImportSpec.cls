/**********************************************************************************
* Name         : DataImportSpec
* Author       : Dalton Wilt
* Desc         : A data-import template, deserialized from the JSON on its
*                Data_Import_Template__mdt record.
*
*                Held as one JSON value on a Custom Metadata record rather than as rows
*                of configuration fields. Rows cannot nest, and a file with a metadata
*                block and two tables is three levels of structure - which is why the
*                framework this replaces needs a new configuration object per level.
*                Custom Metadata rather than a static resource because a template is
*                configuration: it deploys between orgs like code, and can still be
*                corrected in Setup when a program office reissues a workbook
*                mid-quarter.
*
*                A template is a list of sections, because that is what actually varies
*                between real files: where the data starts, and what else is in the file
*                besides the data. Two section types cover it -
*
*                    cells   fixed addresses holding one value each. A metadata block at
*                            the top of a file: reporting period, award number, who
*                            prepared it. Resolved once when the job is prepared and
*                            folded into the job's bindings, so a row 40,000 rows later
*                            can still stamp them onto its records.
*                    rows    a table. Its own row range, its own target object, its own
*                            column map.
*
*                More than one `rows` section is supported, and that is the case that
*                shapes the rest of the design: a chunk from the middle of a large file
*                has to know which table its rows belong to, and Batch Apex does not
*                guarantee chunks are processed in order. So row ranges are resolved
*                before the batch starts and stored on the job - see
*                Data_Import_Job__c.Section_Map__c.
*
*                Columns are named by spreadsheet LETTER, not by heading text. Headings
*                are the part a program office rewords between revisions, and whoever
*                writes a descriptor is looking at the file, not at the code. Rows are
*                one-based for the same reason; every conversion happens on this side.
*
*                    {
*                      "label": "SLFRF Equipment and Supplies",
*                      "sections": [
*                        { "type": "cells", "applyTo": "defaults",
*                          "cells": { "B2": "Report_Period__c" } },
*
*                        { "type": "rows", "sectionName": "equipment",
*                          "target": "SF_428S_Equipment__c",
*                          "startsAfter": "Equipment", "endsAt": "blankRow",
*                          "columns":  { "A": "GP_or_ACQ__c" },
*                          "defaults": { "SLT_Compliance_Report__c": "$reportId" } }
*                      ]
*                    }
* Created On   : 2026-08-03
* Test classes : DataImportSpecTest
*
* Sharing      : public - a template definition carries no record data of its own, so
*                this neither widens nor narrows what its caller can see.
*
* @see DataImportWalker
*
* Modification Log:
* ----------------------------------------------------------------------
* Developer        Date          Description
* ----------------------------------------------------------------------
* Dalton Wilt      2026-08-03    Initial implementation.
**********************************************************************************/

public class DataImportSpec {
  /** Static resource name, set on load so a spec always knows where it came from. */
  public String name;

  /** What the uploader calls this template in its picker. */
  public String label;

  /**
   * 'All or Nothing' (default) or 'Partial Success'.
   *
   * Not the uploader's choice. Whether a file is one submission that must arrive whole is a
   * property of what the file IS — a compliance return and a reference-data load want opposite
   * answers, and the template is what knows which this is.
   *
   * All or Nothing costs two passes: there is no transaction spanning 400,000 rows to roll back, so
   * the only way to promise it is to find out before writing anything. Partial Success asks no such
   * question and therefore makes one pass.
   */
  public String mode;

  /**
   * Errors after which the job stops. Null uses DEFAULT_ABORT_AFTER.
   *
   * A file that fails on every row is the wrong file, and reporting that 400,000 times helps
   * nobody. Under Partial Success the rows already committed stay committed and the job reports
   * that it stopped early rather than that it finished.
   */
  public Integer abortAfterErrors;

  /** How the uploader should size each staged slice. Omit for the default. */
  public Chunk chunk;

  /** The template's blocks, in declaration order. Must contain at least one `rows`
   *  section, or validate() rejects the template on load. */
  public List<Section> sections;

  /** Bad rows tolerated before an import gives up, when the template does not say.
   *  A file failing on every row is the wrong file; reporting it 400,000 times helps
   *  nobody. */
  public static final Integer DEFAULT_ABORT_AFTER = 500;

  /**
   * Slice size, by characters or by rows.
   *
   * Characters is the default because that is what the constraint actually is: a slice lands in a
   * Long Text field capped at 131,072, and rows vary in width. Rows is offered for templates whose
   * width is known and stable, where "500 rows a batch" is easier to reason about than a byte
   * count — but the character ceiling still applies underneath it, or a wide file would produce a
   * slice the field cannot hold.
   *
   * <pre>"chunk": { "rows": 500 }   or   "chunk": { "chars": 60000 }</pre>
   */
  public class Chunk {
    /** Slice size in characters. Wins when both are set. */
    public Integer chars;

    /** Slice size in rows, still capped by the character ceiling underneath. */
    public Integer rows;
  }

  /**
   * One block of a template: either a table of rows, or a set of fixed cell addresses.
   * Which fields apply depends on `type` - a cells section has no target object, and a
   * rows section has no cell map.
   */
  public class Section {
    /** Identifies this section in the job's section map. Required when a template has several. */
    public String sectionName;

    /** 'cells' or 'rows'. */
    public String type;

    // ------------------------------------------------------------------
    // cells
    // ------------------------------------------------------------------

    /** Address to field API name: { "B2": "Report_Period__c" }. */
    public Map<String, String> cells;

    /** 'defaults' stamps the values on every imported record; 'parent' writes them to the job's parent. */
    public String applyTo;

    // ------------------------------------------------------------------
    // rows
    // ------------------------------------------------------------------

    /** SObject API name the rows become. */
    public String target;

    /** One-based first row of data. Set this OR startsAfter. */
    public Integer firstDataRow;

    /** One-based last row of data. Omit when the table runs to the next boundary. */
    public Integer lastDataRow;

    /** Text in the first column that this table begins after, for files whose tables move. */
    public String startsAfter;

    /** 'blankRow' ends the table at the first empty line. Omit when it runs to end of file. */
    public String endsAt;

    /**
     * Text in the first column that ends the table, the row before it.
     *
     * For a table followed immediately by something that is not data — a totals line, a signature
     * block — with no blank row between. Without it that row is read as data: it has values in the
     * mapped columns, so nothing flags it, and it imports as a bogus record.
     *
     * <pre>"endsBefore": "TOTAL"</pre>
     */
    public String endsBefore;

    /**
     * Heading rows between a `startsAfter` marker and the first data row. Defaults to 1.
     *
     * Read by the uploader, which is what locates a moving table. Set it where a template puts two
     * heading rows under its marker, or the first record is skipped with no error.
     */
    public Integer headingRows;

    /** Spreadsheet letter to field API name: { "F": "GP_or_ACQ__c" }. */
    public Map<String, String> columns;

    /** Field API name to a literal or a `$binding`, stamped on every row of this section. */
    public Map<String, String> defaults;

    /**
     * What two or three headings should say: { "F": "GP or ACQ" }, matched as a substring.
     *
     * The cost of mapping by letter. If a reissued file inserts a column, every heading shifts and
     * every row imports SUCCESSFULLY into the wrong fields — descriptions written into GP or ACQ,
     * dates into descriptions — with no error anywhere. This is the only check standing between a
     * reissued workbook and silent corruption, so it is worth setting even though it is optional.
     */
    public Map<String, String> expectHeader;

    /**
     * Turns this section into an insert-or-update. Absent means insert only.
     *
     * <pre>"matchOn": { "column": "H", "field": "Identification_Number__c" }</pre>
     *
     * Resolved by querying for the key values in each chunk and splitting the rows, rather than by
     * Database.upsert — upsert needs a true External Id field and most objects have none.
     */
    public Match matchOn;

    /** One-based row the headings sit on. Only used to check expectHeader. */
    public Integer headerRow;

    /**
     * Several Yes/No columns folding into one multi-select field.
     *
     * Government forms lay a multi-select out sideways: a column per option with Yes or No under
     * it. Every column that reads as Yes contributes its value, joined with ';'; a No, a blank or
     * an unrecognised mark contributes nothing, and a row that selects none of them leaves the
     * field unwritten. The strings must be the picklist values verbatim — one that is not gets
     * named with its column, so a stale config reads as a row error rather than a platform one.
     */
    public List<Grouping> groups;

    /**
     * Write this section's row onto existing child records instead of inserting it.
     *
     * The shape a form takes when its questions are asked once per submission but stored per line
     * item. Only the fields the row actually filled in are copied, so a blank cell leaves each
     * child's own value alone — which is what lets it run over records entered by hand.
     */
    public Broadcast applyToChildren;

    /**
     * @return whether this section is a table of data rows
     */
    public Boolean isRows() {
      return type == 'rows';
    }

    /**
     * @return whether this section is a set of fixed cell addresses
     */
    public Boolean isCells() {
      return type == 'cells';
    }

    /**
     * Zero-based column indexes this section reads — what blank-row detection is judged across.
     *
     * Group option columns count. A row can legitimately carry nothing but a Yes in one of them —
     * on the SF-428C sheet, "request Federal Agency disposition instructions" and nothing else —
     * and judging that row blank would drop it, or end the section early on `endsAt: blankRow`.
     */
    public Set<Integer> columnIndexes() {
      Set<Integer> indexes = new Set<Integer>();
      if (columns != null) {
        for (String letter : columns.keySet()) {
          Integer index = columnIndex(letter);
          if (index != null) {
            indexes.add(index);
          }
        }
      }
      if (groups != null) {
        for (Grouping grouping : groups) {
          if (grouping.options == null) {
            continue;
          }
          for (String letter : grouping.options.keySet()) {
            Integer index = columnIndex(letter);
            if (index != null) {
              indexes.add(index);
            }
          }
        }
      }
      return indexes;
    }
  }

  /** Yes/No columns collapsing into one multi-select. */
  public class Grouping {
    /** The multi-select field the selected options are joined into. */
    public String field;

    /** Spreadsheet letter to the value a "Yes" in that column contributes. */
    public Map<String, String> options;
  }

  /** Applying one row to the existing children of a parent, rather than inserting it. */
  public class Broadcast {
    /** Child SObject to update. Normally the same as the section's target. */
    public String childObject;

    /** Lookup on the child pointing at the parent. */
    public String parentField;

    /** A literal Id or a `$binding` naming the parent whose children to update. */
    public String parentId;
  }

  /** How a row is matched to a record that already exists. */
  public class Match {
    /** Spreadsheet letter holding the key. */
    public String column;

    /** Field on the target holding the same key. */
    public String field;

    /**
     * Whether a blank key is an error rather than an insert.
     *
     * Default false, which is right: a blank key means there is nothing to match, so the row is new.
     * Set it where every row is expected to carry an identifier and a blank one means somebody left
     * a cell empty.
     */
    public Boolean requireKey;

    /**
     * @return whether a blank key is an error rather than an insert; false unless the
     *         template says otherwise, since most templates add as well as update
     */
    public Boolean isKeyRequired() {
      return requireKey == true;
    }
  }

  // ------------------------------------------------------------------
  // Derived
  // ------------------------------------------------------------------

  /**
   * @return whether the whole file must be clean before anything is written; true
   *         unless the template opts into 'Partial Success', because silently keeping
   *         some rows is the more surprising default
   */
  public Boolean isAllOrNothing() {
    return mode == null || mode == 'All or Nothing';
  }

  /**
   * @return how many bad rows to tolerate before giving up on the file, falling back
   *         to DEFAULT_ABORT_AFTER when the template does not say
   */
  public Integer abortThreshold() {
    return abortAfterErrors == null ||
      abortAfterErrors <= 0
      ? DEFAULT_ABORT_AFTER
      : abortAfterErrors;
  }

  /**
   * How many rows of the file are header, and so must be preserved verbatim to rebuild a reject
   * file the same template can parse.
   */
  public Integer headerDepth() {
    Integer depth = cellRowDepth();
    for (Section section : rowSections()) {
      Integer above = section.firstDataRow == null
        ? 0
        : section.firstDataRow - 1;
      if (above > depth) {
        depth = above;
      }
      if (section.headerRow != null && section.headerRow > depth) {
        depth = section.headerRow;
      }
    }
    return depth;
  }

  /**
   * @return every table in the template, in declaration order; empty is impossible -
   *         validate() rejects a template with no rows section
   */
  public List<Section> rowSections() {
    List<Section> found = new List<Section>();
    for (Section section : sections) {
      if (section.isRows()) {
        found.add(section);
      }
    }
    return found;
  }

  /**
   * @return every fixed-address section, in declaration order; empty when the template
   *         has no metadata block
   */
  public List<Section> cellSections() {
    List<Section> found = new List<Section>();
    for (Section section : sections) {
      if (section.isCells()) {
        found.add(section);
      }
    }
    return found;
  }

  /**
   * Finds a section by the name the job's section map refers to it by.
   *
   * @param wanted the section name; null matches a template's single unnamed section
   * @return       the section, or null when no section carries that name
   */
  public Section sectionNamed(String wanted) {
    for (Section section : sections) {
      if (section.sectionName == wanted) {
        return section;
      }
    }
    return null;
  }

  /** How far into the file the uploader must read before it can resolve the `cells` sections. */
  public Integer cellRowDepth() {
    Integer deepest = 0;
    for (Section section : cellSections()) {
      if (section.cells == null) {
        continue;
      }
      for (String address : section.cells.keySet()) {
        Integer row = rowOf(address);
        if (row != null && row > deepest) {
          deepest = row;
        }
      }
    }
    return deepest;
  }

  // ------------------------------------------------------------------
  // Addressing
  // ------------------------------------------------------------------

  /** 'A' -> 0, 'AA' -> 26. Null for anything that is not a column letter. */
  public static Integer columnIndex(String letter) {
    if (String.isBlank(letter)) {
      return null;
    }
    String upper = letter.trim().toUpperCase();
    Integer index = 0;
    for (Integer i = 0; i < upper.length(); i++) {
      Integer position = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ'
        .indexOf(upper.substring(i, i + 1));
      if (position < 0) {
        return null;
      }
      index = index * 26 + (position + 1);
    }
    return index - 1;
  }

  /** Zero-based column of an 'A1'-style address. */
  public static Integer columnOf(String address) {
    Matcher m = addressMatcher(address);
    return m == null ? null : columnIndex(m.group(1));
  }

  /** One-based row of an 'A1'-style address. */
  public static Integer rowOf(String address) {
    Matcher m = addressMatcher(address);
    return m == null ? null : Integer.valueOf(m.group(2));
  }

  private static Matcher addressMatcher(String address) {
    if (String.isBlank(address)) {
      return null;
    }
    Matcher m = Pattern.compile('^([A-Za-z]+)([0-9]+)$')
      .matcher(address.trim());
    return m.matches() ? m : null;
  }

  // ------------------------------------------------------------------
  // Loading
  // ------------------------------------------------------------------

  /**
   * Definitions by DeveloperName, standing in for the Custom Metadata.
   *
   * Not a convenience: Custom Metadata records cannot be inserted from Apex, so a test has no other
   * way to exercise a template. Every test in this package sets this.
   */
  @TestVisible
  private static Map<String, String> jsonOverride;

  private static Map<String, DataImportSpec> cache = new Map<String, DataImportSpec>();

  /**
   * One template by its Data_Import_Template__mdt DeveloperName.
   *
   * Read by SOQL, NOT by getInstance(). Custom Metadata fetched through getInstance() or getAll()
   * has its long text fields truncated to 255 characters, which silently corrupts every definition
   * longer than that — the JSON simply stops mid-object. getInstance() costs no query and would be
   * the obvious choice; it cannot be used here.
   *
   * The per-transaction cache below is what keeps the cost to one query however many chunks a
   * batch runs, which is what getInstance() was reached for in the first place.
   *
   * @throws DataImport.DataImportException when it does not exist, is inactive, or will not load
   */
  public static DataImportSpec load(String templateName) {
    String key = String.isBlank(templateName) ? '' : templateName.trim();
    if (cache.containsKey(key)) {
      return cache.get(key);
    }

    String body;
    if (jsonOverride != null) {
      body = jsonOverride.get(key);
    } else {
      List<Data_Import_Template__mdt> found = [
        SELECT DeveloperName, Definition__c, Active__c
        FROM Data_Import_Template__mdt
        WHERE DeveloperName = :key
        LIMIT 1
      ];
      if (!found.isEmpty() && found[0].Active__c == false) {
        throw new DataImport.DataImportException(
          'Import template "' + key + '" is no longer active.'
        );
      }
      body = found.isEmpty() ? null : found[0].Definition__c;
    }
    if (String.isBlank(body)) {
      throw new DataImport.DataImportException(
        'No import template named "' + key + '" is configured.'
      );
    }

    DataImportSpec spec;
    try {
      spec = (DataImportSpec) JSON.deserialize(body, DataImportSpec.class);
    } catch (Exception e) {
      throw new DataImport.DataImportException(
        'Import template "' + key + '" is not valid JSON: ' + e.getMessage()
      );
    }
    spec.name = key;
    spec.validate();
    cache.put(key, spec);
    return spec;
  }

  /**
   * Every active template, for the uploader's picker.
   *
   * getAll() is safe here and only here: the picker needs Label and DeveloperName, never the
   * definition, so the 255-character truncation on long text fields cannot bite.
   */
  public static List<Data_Import_Template__mdt> available() {
    List<Data_Import_Template__mdt> active = new List<Data_Import_Template__mdt>();
    for (
      Data_Import_Template__mdt template : Data_Import_Template__mdt.getAll()
        .values()
    ) {
      if (template.Active__c == true) {
        active.add(template);
      }
    }
    return active;
  }

  /**
   * Fail a broken template at load rather than at row 40,000.
   *
   * Everything checked here is a mistake by whoever wrote the descriptor, never something a person
   * uploading a file can cause — so these messages name the template and the fault, and never
   * suggest a fix to the uploader.
   */
  @TestVisible
  private void validate() {
    List<String> faults = new List<String>();
    if (sections == null || sections.isEmpty()) {
      faults.add('no sections');
      throwFaults(faults);
    }

    Integer rowSectionCount = 0;
    for (Section section : sections) {
      if (section.isRows()) {
        rowSectionCount++;
        if (String.isBlank(section.target)) {
          faults.add('a rows section with no target');
        } else if (Schema.getGlobalDescribe().get(section.target) == null) {
          faults.add(
            'target "' + section.target + '" is not an object in this org'
          );
        }
        if (section.columns == null || section.columns.isEmpty()) {
          faults.add('a rows section with no columns');
        }
        if (
          section.firstDataRow == null && String.isBlank(section.startsAfter)
        ) {
          faults.add(
            'a rows section with neither firstDataRow nor startsAfter'
          );
        }
      } else if (!section.isCells()) {
        faults.add(
          'section type "' + section.type + '" is not "cells" or "rows"'
        );
      }
    }

    if (rowSectionCount == 0) {
      faults.add('no rows section, so nothing would be imported');
    }
    if (rowSectionCount > 1) {
      for (Section section : rowSections()) {
        if (String.isBlank(section.sectionName)) {
          faults.add(
            'every rows section needs a sectionName when a template has more than one'
          );
          break;
        }
      }
    }
    throwFaults(faults);
  }

  private void throwFaults(List<String> faults) {
    if (faults.isEmpty()) {
      return;
    }
    throw new DataImport.DataImportException(
      'Import template "' + name + '": ' + String.join(faults, '; ') + '.'
    );
  }

  @TestVisible
  private static void clearCache() {
    cache = new Map<String, DataImportSpec>();
  }
}
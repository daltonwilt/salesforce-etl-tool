/**********************************************************************************
* Name         : DataImport
* Author       : Dalton Wilt
* Desc         : Shared data-import helpers for CSV templates recipients fill in
*                and upload back.
*
*                The generic half of a template import: read the uploaded file, parse
*                it properly, and turn cell text into typed field values with a
*                readable message for anything that will not convert. What stays with
*                each form is the part that is actually its own - where its header and
*                data rows sit, how its columns map to fields, and what to do with the
*                rows once they are built.
*
*                A form-specific importer therefore looks like:
*
*                    List<List<String>> rows = DataImport.read(contentDocumentId);
*                    DataImport.Coercer coercer =
*                        new DataImport.Coercer(My_Object__c.SObjectType);
*                    List<String> errors = new List<String>();
*                    for (Integer r = FIRST_DATA_ROW; r < rows.size(); r++) {
*                        My_Object__c record = new My_Object__c();
*                        coercer.assign(record, 'Acquired_Date__c',
*                                       DataImport.cell(rows[r], 4),
*                                       'Row ' + (r + 1), errors);
*                    }
*
*                Deliberately NOT built on UploadStandard / Parse_CSV_Utility, which
*                back the generic <c-file-reader>. Those map the header row straight
*                onto API field names, so the template has to carry a row of API names,
*                and Parse_CSV_Utility splits on '\r\n' and then on ',' - its own
*                comment says it does not handle newlines inside a field. Templates
*                authored by a program office have prose headings and multi-line help
*                text in quoted cells, and both defeat that path.
*
*                Collect errors rather than throwing on the first one, and write nothing
*                until the whole file has been checked: a partial import leaves the
*                recipient reconciling half a record set against their spreadsheet.
* Created On   : 2026-08-03
* Test classes : DataImportTest
*
* Sharing      : inherited sharing - parsing and coercion carry no record access of
*                their own, so this runs in whatever context its caller declared.
*
* @see DataImportWalker
*
* Modification Log:
* ----------------------------------------------------------------------
* Developer        Date          Description
* ----------------------------------------------------------------------
* Dalton Wilt      2026-08-03    Initial implementation.
**********************************************************************************/

public inherited sharing class DataImport {
  /** Thrown for anything the recipient can fix: wrong file, bad cell, nothing to import. */
  public class DataImportException extends Exception {
  }

  /** How many bad cells a rejection message lists before it summarises the rest. */
  private static final Integer MAX_REPORTED_ERRORS = 10;

  // ------------------------------------------------------------------
  // Reading the upload
  // ------------------------------------------------------------------

  /**
   * The uploaded file as rows of cells.
   *
   * @param contentDocumentId the ContentDocument the file was uploaded as
   * @return                  every row, header rows included — the caller knows where its data starts
   * @throws DataImportException when the document is missing, or is not a .csv
   */
  public static List<List<String>> read(String contentDocumentId) {
    List<ContentVersion> versions = [
      SELECT Id, VersionData, PathOnClient
      FROM ContentVersion
      WHERE ContentDocumentId = :contentDocumentId AND IsLatest = TRUE
      LIMIT 1
    ];
    if (versions.isEmpty()) {
      throw new DataImportException(
        'The uploaded file could not be found. Please try uploading it again.'
      );
    }
    String name = versions[0].PathOnClient;
    if (String.isNotBlank(name) && !name.toLowerCase().endsWith('.csv')) {
      throw new DataImportException(
        'Only .csv files can be uploaded. Open the template, save it as a .csv, and upload that file.'
      );
    }
    return parse(versions[0].VersionData.toString());
  }

  /**
   * RFC 4180 parse: quoted fields, doubled quotes, and newlines inside a quoted field.
   *
   * Lines are re-joined rather than scanned character by character wherever possible. A template's
   * instruction block is routinely one quoted cell spanning ten lines, and a character loop over a
   * file of a few hundred data rows is what puts an import over the Apex CPU limit. A line only
   * reaches the character parser when it actually contains a quote.
   *
   * @param content the file body
   * @return        rows of cells; an empty list for empty input
   */
  public static List<List<String>> parse(String content) {
    List<List<String>> rows = new List<List<String>>();
    if (String.isBlank(content)) {
      return rows;
    }

    List<String> lines = content.replace('\r\n', '\n')
      .replace('\r', '\n')
      .split('\n', -1);

    String pending = null;
    for (String line : lines) {
      String record = pending == null ? line : pending + '\n' + line;
      // An odd number of quotes means the record is still inside a quoted cell: doubled quotes ("")
      // contribute two, so only an unclosed opening quote leaves the count odd.
      if (Math.mod(record.countMatches('"'), 2) == 1) {
        pending = record;
        continue;
      }
      pending = null;
      rows.add(parseRecord(record));
    }
    // An unterminated quote at end of file — take what is there rather than dropping the row.
    if (pending != null) {
      rows.add(parseRecord(pending));
    }
    return rows;
  }

  /** One logical record to cells. Falls back to a plain split when there is nothing to unquote. */
  private static List<String> parseRecord(String record) {
    if (!record.contains('"')) {
      return record.split(',', -1);
    }

    List<String> cells = new List<String>();
    String field = '';
    Boolean inQuotes = false;
    Integer i = 0;
    Integer len = record.length();

    while (i < len) {
      String ch = record.substring(i, i + 1);
      if (inQuotes) {
        if (ch == '"') {
          if (i + 1 < len && record.substring(i + 1, i + 2) == '"') {
            field += '"';
            i += 2;
            continue;
          }
          inQuotes = false;
        } else {
          field += ch;
        }
      } else if (ch == '"') {
        inQuotes = true;
      } else if (ch == ',') {
        cells.add(field);
        field = '';
      } else {
        field += ch;
      }
      i++;
    }
    cells.add(field);
    return cells;
  }

  // ------------------------------------------------------------------
  // Cells
  // ------------------------------------------------------------------

  /**
   * The trimmed cell at a column index, or ''.
   *
   * Short rows are normal in a sheet saved from Excel — trailing empty columns are dropped — so a
   * column index past the end of the row is not an error.
   */
  public static String cell(List<String> row, Integer col) {
    if (row == null || col == null || col >= row.size() || row[col] == null) {
      return '';
    }
    return row[col].trim();
  }

  /**
   * Whether a row is empty across the columns that matter.
   *
   * Scoped to the given columns rather than the whole row because templates carry legend and
   * row-counter columns that are populated on every line and are not data.
   */
  public static Boolean isRowBlank(List<String> row, Set<Integer> columns) {
    for (Integer col : columns) {
      if (String.isNotBlank(cell(row, col))) {
        return false;
      }
    }
    return true;
  }

  /**
   * A Yes/No column as recipients actually fill it in — a tick, a Y, a 1 or the word.
   *
   * Anything else, blank included, is No. These columns usually select an option rather than answer
   * a question, so an unrecognised mark must not turn one on.
   */
  public static Boolean isYes(String value) {
    if (String.isBlank(value)) {
      return false;
    }
    String text = value.trim().toLowerCase();
    return text == 'yes' ||
      text == 'y' ||
      text == 'true' ||
      text == 'x' ||
      text == '1';
  }

  // ------------------------------------------------------------------
  // Coercion
  // ------------------------------------------------------------------

  /**
   * Turns cell text into typed field values for one SObject type.
   *
   * An instance rather than static methods so the describe is taken once per import. Describing per
   * cell is the difference between one describe and one per field per row, which is what makes a
   * few hundred rows fail on limits.
   *
   * Every method appends to the caller's error list rather than throwing, so one unreadable cell
   * does not hide the rest of the file.
   */
  public class Coercer {
    private final Map<String, Schema.DescribeFieldResult> describes = new Map<String, Schema.DescribeFieldResult>();
    private final Map<String, Set<String>> picklistValues = new Map<String, Set<String>>();
    private final Map<String, Schema.SObjectField> fields;
    private final String objectName;

    /**
     * @param type the SObject the imported records are of
     */
    public Coercer(Schema.SObjectType type) {
      Schema.DescribeSObjectResult describe = type.getDescribe();
      this.objectName = describe.getName();
      this.fields = describe.fields.getMap();
    }

    /**
     * Coerce one cell and set it on a record, skipping blanks.
     *
     * A blank cell leaves the field untouched rather than clearing it, so an import can be run over
     * records that were partly filled in by hand.
     *
     * @param record   the record being built or updated
     * @param apiName  the field to set
     * @param value    the raw cell text
     * @param rowLabel how this row should be named in an error message, e.g. 'Row 8'
     * @param errors   collects one message per cell that could not be read
     */
    public void assign(
      SObject record,
      String apiName,
      String value,
      String rowLabel,
      List<String> errors
    ) {
      if (String.isBlank(value)) {
        return;
      }
      Object coerced = coerce(apiName, value, rowLabel, errors);
      if (coerced != null) {
        record.put(apiName, coerced);
      }
    }

    /**
     * Cell text as the field's own type.
     *
     * Templates normally instruct recipients to enter everything as text, so currency and percent
     * columns routinely carry $, %, thousands commas and accounting parentheses.
     *
     * @return the typed value, or null when the text could not be read as that type — in which case
     *         a message has been appended to `errors`
     */
    public Object coerce(
      String apiName,
      String value,
      String rowLabel,
      List<String> errors
    ) {
      Schema.DescribeFieldResult describe = describeField(apiName);
      Schema.DisplayType type = describe.getType();
      String text = value.trim();

      if (type == Schema.DisplayType.BOOLEAN) {
        return DataImport.isYes(text);
      }

      if (type == Schema.DisplayType.DATE) {
        Date parsed = parseDate(text);
        if (parsed == null) {
          errors.add(
            message(rowLabel, describe, text, 'is not a date. Use MM/DD/YYYY.')
          );
          return null;
        }
        return parsed;
      }

      if (type == Schema.DisplayType.DATETIME) {
        Date parsed = parseDate(text);
        if (parsed == null) {
          errors.add(
            message(rowLabel, describe, text, 'is not a date. Use MM/DD/YYYY.')
          );
          return null;
        }
        return Datetime.newInstance(parsed, Time.newInstance(0, 0, 0, 0));
      }

      if (
        type == Schema.DisplayType.CURRENCY ||
        type == Schema.DisplayType.PERCENT ||
        type == Schema.DisplayType.DOUBLE ||
        type == Schema.DisplayType.INTEGER ||
        type == Schema.DisplayType.LONG
      ) {
        Decimal parsed = parseDecimal(text);
        if (parsed == null) {
          errors.add(message(rowLabel, describe, text, 'is not a number.'));
          return null;
        }
        if (type == Schema.DisplayType.INTEGER) {
          // Decimal.round() hands back a Long, and a Long will not assign to an Integer field.
          return Integer.valueOf(parsed.round(System.RoundingMode.HALF_UP));
        }
        if (type == Schema.DisplayType.LONG) {
          return parsed.round(System.RoundingMode.HALF_UP);
        }
        return parsed;
      }

      if (
        type == Schema.DisplayType.PICKLIST ||
        type == Schema.DisplayType.MULTIPICKLIST
      ) {
        Set<String> allowed = allowedValues(apiName);
        String matched = matchPicklist(allowed, text);
        if (matched == null) {
          errors.add(
            message(
              rowLabel,
              describe,
              text,
              'is not one of the allowed values (' +
                String.join(new List<String>(allowed), ', ') +
                ').'
            )
          );
          return null;
        }
        return matched;
      }

      Integer maxLength = describe.getLength();
      if (maxLength > 0 && text.length() > maxLength) {
        errors.add(
          message(
            rowLabel,
            describe,
            text.abbreviate(40),
            'is longer than the ' + maxLength + ' characters this field allows.'
          )
        );
        return null;
      }
      return text;
    }

    /** Active values for a picklist field, for validating a cell before the platform sees it. */
    public Set<String> allowedValues(String apiName) {
      if (picklistValues.containsKey(apiName)) {
        return picklistValues.get(apiName);
      }
      Set<String> values = new Set<String>();
      for (
        Schema.PicklistEntry entry : describeField(apiName).getPicklistValues()
      ) {
        if (entry.isActive()) {
          values.add(entry.getValue());
        }
      }
      picklistValues.put(apiName, values);
      return values;
    }

    /** Case-insensitive match to an active value, returned in the picklist's own casing. */
    private String matchPicklist(Set<String> allowed, String text) {
      if (allowed == null || allowed.isEmpty()) {
        return text;
      }
      for (String value : allowed) {
        if (value.equalsIgnoreCase(text)) {
          return value;
        }
      }
      return null;
    }

    /** Described once per field per import. An unknown API name is a coding error, not a bad file. */
    private Schema.DescribeFieldResult describeField(String apiName) {
      if (describes.containsKey(apiName)) {
        return describes.get(apiName);
      }
      Schema.SObjectField field = fields.get(apiName);
      if (field == null) {
        throw new DataImportException(
          'No field ' + apiName + ' on ' + objectName + '.'
        );
      }
      Schema.DescribeFieldResult describe = field.getDescribe();
      describes.put(apiName, describe);
      return describe;
    }

    private String message(
      String rowLabel,
      Schema.DescribeFieldResult describe,
      String text,
      String problem
    ) {
      return rowLabel +
        ', ' +
        describe.getLabel() +
        ': "' +
        text +
        '" ' +
        problem;
    }
  }

  // ------------------------------------------------------------------
  // Parsing primitives
  // ------------------------------------------------------------------

  /**
   * MM/DD/YYYY as templates normally ask for, or the ISO form Excel writes on some locales.
   *
   * @return null when the text is neither
   */
  public static Date parseDate(String text) {
    if (String.isBlank(text)) {
      return null;
    }
    String trimmed = text.trim();
    try {
      if (Pattern.matches('\\d{4}-\\d{1,2}-\\d{1,2}', trimmed)) {
        return Date.valueOf(trimmed);
      }
      if (Pattern.matches('\\d{1,2}/\\d{1,2}/\\d{4}', trimmed)) {
        List<String> parts = trimmed.split('/');
        Integer month = Integer.valueOf(parts[0]);
        Integer day = Integer.valueOf(parts[1]);
        Date parsed = Date.newInstance(Integer.valueOf(parts[2]), month, day);
        // Date.newInstance ROLLS OVER rather than throwing — 13/45/2026 becomes 2027-02-14, and a
        // typo would import as a real date. Reject anything the calendar moved.
        return (parsed.month() == month && parsed.day() == day) ? parsed : null;
      }
    } catch (Exception e) {
      return null;
    }
    return null;
  }

  /**
   * A number as Excel leaves it — strips $, %, thousands commas, and reads accounting parentheses
   * as negative.
   *
   * @return null when nothing numeric is left
   */
  public static Decimal parseDecimal(String text) {
    if (String.isBlank(text)) {
      return null;
    }
    String trimmed = text.trim();
    Boolean negative = trimmed.startsWith('(') && trimmed.endsWith(')');
    String cleaned = trimmed.replaceAll('[^0-9.\\-]', '');
    if (String.isBlank(cleaned) || cleaned == '-' || cleaned == '.') {
      return null;
    }
    try {
      Decimal parsed = Decimal.valueOf(cleaned);
      return negative ? -parsed.abs() : parsed;
    } catch (Exception e) {
      return null;
    }
  }

  // ------------------------------------------------------------------
  // Errors
  // ------------------------------------------------------------------

  /**
   * The collected cell errors as one rejection message, capped so a wholly mis-saved file does not
   * return a wall of text.
   */
  public static String errorMessage(List<String> errors) {
    return errorMessage('This file could not be imported:', errors);
  }

  /**
   * The same, under a caller-supplied heading.
   *
   * @param heading the first line, naming what failed
   * @param errors  the collected messages, in the order they were found
   * @return        the heading and up to MAX_REPORTED_ERRORS messages, with a count of
   *                whatever was left out
   */
  public static String errorMessage(String heading, List<String> errors) {
    Integer shown = Math.min(errors.size(), MAX_REPORTED_ERRORS);
    List<String> head = new List<String>();
    for (Integer i = 0; i < shown; i++) {
      head.add(errors[i]);
    }
    String message = heading + '\n' + String.join(head, '\n');
    if (errors.size() > shown) {
      message += '\n…and ' + (errors.size() - shown) + ' more.';
    }
    return message;
  }
}
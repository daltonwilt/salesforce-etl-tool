/**********************************************************************************
* Name         : DataImportJob
* Author       : Dalton Wilt
* Desc         : The client boundary for a data import, and the prepare step that runs
*                before the batch.
*
*                The flow is deliberately four calls rather than one, because the file
*                is sliced in the browser and never exists whole inside Apex - which is
*                the single decision that removes the ceiling on file size:
*
*                    1. getTemplate   what the uploader needs to slice the file and
*                                     check it
*                    2. start         create the job, with the section ranges the
*                                     uploader worked out
*                    3. stage         once per slice
*                    4. run           prepare, then hand off to DataImportBatch
*
*                `prepare` is where everything that is the same for every row happens:
*                capture the header block, resolve the `cells` sections, assert the
*                headings have not shifted, and check the running user can actually
*                write every mapped field. Each of those would otherwise be repeated per
*                row, and two of them would be wrong per row - a missing permission is
*                one message, not forty thousand.
* Created On   : 2026-08-03
* Test classes : DataImportJobTest
*
* Sharing      : with sharing - these are the @AuraEnabled entry points a portal user
*                calls, so they run against what that user can actually see.
*
* @see DataImportBatch
*
* Modification Log:
* ----------------------------------------------------------------------
* Developer        Date          Description
* ----------------------------------------------------------------------
* Dalton Wilt      2026-08-03    Initial implementation.
**********************************************************************************/

public with sharing class DataImportJob {
  /** How the uploader starts a job. */
  public class Request {
    /** DeveloperName of the Data_Import_Template__mdt record to import against. */
    @AuraEnabled
    public String template { get; set; }

    /** The uploaded file's name, kept so the reject file can be named after it. */
    @AuraEnabled
    public String fileName { get; set; }

    /** How many slices the uploader will stage. run() refuses a job whose chunks
     *  have not all arrived. */
    @AuraEnabled
    public Integer totalChunks { get; set; }

    /** JSON map of `$placeholder` values the template's defaults resolve against. */
    @AuraEnabled
    public String bindingsJson { get; set; }

    /**
     * JSON array of { sectionName, firstRow, lastRow }, worked out by the uploader while it read
     * the file. A table whose length is not known until the file is read cannot be located any
     * other way, and a chunk cannot infer it from the chunk before — Batch Apex does not promise
     * to run them in order.
     */
    @AuraEnabled
    public String sectionMapJson { get; set; }
  }

  /** What the uploader needs before it starts slicing. */
  public class TemplateInfo {
    /** DeveloperName, which is what start() expects back. */
    @AuraEnabled
    public String name { get; set; }

    /** Display label, for the template picker. */
    @AuraEnabled
    public String label { get; set; }

    /** The raw template JSON. The uploader needs it to work out where each section
     *  starts and ends before it can slice the file. */
    @AuraEnabled
    public String definition { get; set; }

    /** Whether a single bad row stops the whole import, so the uploader can say so
     *  before the file is sent rather than after. */
    @AuraEnabled
    public Boolean allOrNothing { get; set; }

    /** How many bad rows the import tolerates before giving up. */
    @AuraEnabled
    public Integer abortAfterErrors { get; set; }
  }

  // ------------------------------------------------------------------
  // Client boundary
  // ------------------------------------------------------------------

  /** Every active template, for the picker. */
  @AuraEnabled(cacheable=true)
  public static List<TemplateInfo> getTemplates() {
    List<TemplateInfo> found = new List<TemplateInfo>();
    for (Data_Import_Template__mdt record : DataImportSpec.available()) {
      TemplateInfo info = new TemplateInfo();
      info.name = record.DeveloperName;
      info.label = String.isBlank(record.MasterLabel)
        ? record.DeveloperName
        : record.MasterLabel;
      found.add(info);
    }
    return found;
  }

  /**
   * One template, definition included — the uploader needs the sections to find boundaries and the
   * match column to spot duplicate keys before a job exists.
   */
  @AuraEnabled(cacheable=true)
  public static TemplateInfo getTemplate(String templateName) {
    DataImportSpec spec = DataImportSpec.load(templateName);
    TemplateInfo info = new TemplateInfo();
    info.name = spec.name;
    info.label = String.isBlank(spec.label) ? spec.name : spec.label;
    info.definition = JSON.serialize(spec);
    info.allOrNothing = spec.isAllOrNothing();
    info.abortAfterErrors = spec.abortThreshold();
    return info;
  }

  /** Create the job. Loading the template here fails a bad name before any chunk is uploaded. */
  @AuraEnabled
  public static Id start(Request request) {
    try {
      DataImportSpec spec = DataImportSpec.load(request.template);
      Data_Import_Job__c job = new Data_Import_Job__c(
        Template__c = spec.name,
        File_Name__c = request.fileName,
        Total_Chunks__c = request.totalChunks,
        Bindings__c = request.bindingsJson,
        Section_Map__c = request.sectionMapJson,
        Mode__c = spec.isAllOrNothing() ? 'All or Nothing' : 'Partial Success',
        Status__c = 'Staging'
      );
      insert job;
      return job.Id;
    } catch (Exception e) {
      throw reportable(e.getMessage());
    }
  }

  /**
   * Stage one slice.
   *
   * The uploader only ever splits on a line break outside a quoted cell, so a chunk always parses
   * on its own — no chunk depends on the one before it.
   */
  @AuraEnabled
  public static void stage(
    Id jobId,
    Integer sequence,
    Integer firstRowNumber,
    String body
  ) {
    try {
      insert new Data_Import_Chunk__c(
        Job__c = jobId,
        Sequence__c = sequence,
        First_Row_Number__c = firstRowNumber,
        Body__c = body
      );
    } catch (Exception e) {
      throw reportable(e.getMessage());
    }
  }

  /**
   * Prepare, then hand off to the batch.
   *
   * The section map arrives here rather than at start() because it is not known until the file has
   * been read, and the job has to exist before a chunk can point at it. So the job is created
   * empty, filled by staging, and told what it contains at the end.
   *
   * @param sectionMapJson resolved row ranges from the uploader; null for a single fixed-offset table
   */
  @AuraEnabled
  public static void run(Id jobId, Integer totalChunks, String sectionMapJson) {
    try {
      Data_Import_Job__c job = load(jobId);
      DataImportSpec spec = DataImportSpec.load(job.Template__c);
      if (totalChunks != null) {
        job.Total_Chunks__c = totalChunks;
      }
      if (String.isNotBlank(sectionMapJson)) {
        job.Section_Map__c = sectionMapJson;
      }
      prepare(job, spec);
      job.Status__c = 'Queued';
      update job;
      Database.executeBatch(new DataImportBatch(jobId, 'Validate'), 1);
    } catch (Exception e) {
      fail(jobId, e.getMessage());
      throw reportable(e.getMessage());
    }
  }

  /**
   * One page of the rejected rows, for the uploader to assemble into a download.
   *
   * Paged rather than returned whole, and assembled in the browser rather than in Apex, for the
   * same reason the upload is chunked: a file that is too large to hold in heap is exactly the case
   * this framework exists for. Building it server-side would reimpose a ceiling on the way out that
   * was carefully avoided on the way in — and would need Files permissions a portal user lacks.
   *
   * @param afterSequence the last sequence already fetched; null or -1 starts from the beginning
   */
  @AuraEnabled
  public static RejectPage getRejectRows(Id jobId, Decimal afterSequence) {
    Decimal after = afterSequence == null ? -1 : afterSequence;
    List<Data_Import_Chunk__c> chunks = [
      SELECT Sequence__c, Section__c, Body__c
      FROM Data_Import_Chunk__c
      WHERE Job__c = :jobId AND Is_Reject__c = TRUE AND Sequence__c > :after
      ORDER BY Sequence__c ASC
      LIMIT 6
    ];

    RejectPage page = new RejectPage();
    page.rows = new List<RejectRows>();
    for (Data_Import_Chunk__c chunk : chunks) {
      RejectRows rows = new RejectRows();
      rows.section = chunk.Section__c;
      rows.body = chunk.Body__c;
      page.rows.add(rows);
      page.lastSequence = chunk.Sequence__c;
    }
    page.hasMore = chunks.size() == 6;

    // The header block only comes back on the first page — it belongs at the top of the file once.
    if (after < 0) {
      Data_Import_Job__c job = load(jobId);
      page.fileName = job.File_Name__c;
      page.header = job.Header_Rows__c;
    }
    return page;
  }

  /** A page of rejected rows, in the order they appeared in the file. */
  public class RejectPage {
    /** What the assembled download should be called, derived from the upload. */
    @AuraEnabled
    public String fileName { get; set; }

    /** The original header block, carried on the FIRST page only, so the download
     *  the recipient corrects and re-uploads is shaped like the file they sent. */
    @AuraEnabled
    public String header { get; set; }

    /** This page's rejected rows, in the order they appeared in the file. */
    @AuraEnabled
    public List<RejectRows> rows { get; set; }

    /** Pass back as `afterSequence` to fetch the next page. */
    @AuraEnabled
    public Decimal lastSequence { get; set; }

    /** Whether another page follows. Paged rather than returned whole because a
     *  wholly bad file rejects every row it contains. */
    @AuraEnabled
    public Boolean hasMore { get; set; }
  }

  /** One chunk of rejected rows as CSV, ready to be concatenated into the download. */
  public class RejectRows {
    /** Which template section these came from; null for a single-table template. */
    @AuraEnabled
    public String section { get; set; }
    /** The rejected rows as CSV, each already annotated with why it failed. */
    @AuraEnabled
    public String body { get; set; }
  }

  /** Progress, for polling. Not cacheable — the whole point is that it changes. */
  @AuraEnabled
  public static Data_Import_Job__c status(Id jobId) {
    return load(jobId);
  }

  // ------------------------------------------------------------------
  // Prepare
  // ------------------------------------------------------------------

  /**
   * Everything that is the same for every row, done once before any row is read.
   *
   * Order matters: permissions first, because a job the running user could never complete should
   * cost nothing. Then the headings, because a shifted column corrupts silently and must stop the
   * job rather than produce errors. Only then the file's own content.
   */
  @TestVisible
  private static void prepare(Data_Import_Job__c job, DataImportSpec spec) {
    assertWritable(spec);

    List<Data_Import_Chunk__c> head = [
      SELECT Body__c, First_Row_Number__c
      FROM Data_Import_Chunk__c
      WHERE Job__c = :job.Id AND Is_Reject__c = FALSE
      ORDER BY Sequence__c ASC
      LIMIT 1
    ];
    if (head.isEmpty()) {
      throw new DataImport.DataImportException(
        'This import has no file attached to it. Please try uploading again.'
      );
    }

    List<List<String>> rows = DataImport.parse(head[0].Body__c);
    assertHeaders(spec, rows);
    job.Header_Rows__c = captureHeader(spec, rows);

    // Checked AFTER the cells sections are read, not before: a binding can come from the caller OR
    // from the top of the file itself, and only the merged set says what a row will actually have.
    Map<String, Object> bindings = resolveCells(spec, rows, job.Bindings__c);
    assertBindingsSupplied(spec, bindings);
    job.Bindings__c = JSON.serialize(bindings);
  }

  /**
   * Refuse the job when the running user cannot write something the template maps.
   *
   * Not stripInaccessible, which drops such fields silently and leaves records quietly incomplete.
   * A missing grant is identical on every row, so it is one message, up front, naming exactly what
   * to grant or remove.
   */
  @TestVisible
  private static void assertWritable(DataImportSpec spec) {
    List<String> denied = new List<String>();
    for (DataImportSpec.Section section : spec.rowSections()) {
      // What the section actually does decides which permission matters. A broadcast only ever
      // updates; a matchOn does either. Checking create alone let an update-only template through
      // pre-flight and then failed every single row at DML, which is the opposite of the point.
      Boolean inserts = section.applyToChildren == null;
      Boolean updates =
        section.applyToChildren != null ||
        section.matchOn != null;

      String targetName = section.applyToChildren == null
        ? section.target
        : section.applyToChildren.childObject;
      Schema.DescribeSObjectResult target = Schema.getGlobalDescribe()
        .get(targetName)
        .getDescribe();

      if (inserts && !target.isCreateable()) {
        denied.add('create ' + target.getLabel());
        continue;
      }
      if (updates && !target.isUpdateable()) {
        denied.add('edit ' + target.getLabel());
        continue;
      }

      Map<String, Schema.SObjectField> fields = target.fields.getMap();
      Set<String> written = new Set<String>(section.columns.values());
      if (section.defaults != null) {
        written.addAll(section.defaults.keySet());
      }
      if (section.groups != null) {
        for (DataImportSpec.Grouping grouping : section.groups) {
          written.add(grouping.field);
        }
      }
      for (String apiName : written) {
        Schema.SObjectField field = fields.get(apiName);
        if (field == null) {
          denied.add(apiName + ' (no such field on ' + target.getLabel() + ')');
          continue;
        }
        Schema.DescribeFieldResult describe = field.getDescribe();
        Boolean writable = inserts
          ? describe.isCreateable()
          : describe.isUpdateable();
        if (!writable) {
          denied.add(target.getLabel() + '.' + describe.getLabel());
        }
      }
    }
    if (!denied.isEmpty()) {
      throw new DataImport.DataImportException(
        'This import cannot run. You do not have permission to write: ' +
          String.join(denied, ', ') +
          '. Ask for access, or have these removed from the template.'
      );
    }
  }

  /**
   * Refuse a template whose parent lookups have nothing to resolve to.
   *
   * A `$binding` that the caller did not supply is left unset rather than guessed at, which means
   * the records import with no parent — orphans nothing can reach. That is silent and permanent, so
   * it has to stop the job rather than produce a row error.
   *
   * The case this exists for: running a template built for a host component (SF-428, which supplies
   * $requestId and $reportId) from the standalone importer, which supplies nothing.
   *
   * @param supplied the MERGED set — what the caller passed plus whatever the file's own cells
   *                 sections yielded. A template reading its award number out of cell B2 resolves
   *                 perfectly well even though no caller supplied it, which is why this cannot run
   *                 before resolveCells.
   */
  @TestVisible
  private static void assertBindingsSupplied(
    DataImportSpec spec,
    Map<String, Object> supplied
  ) {
    Set<String> unresolved = new Set<String>();
    for (DataImportSpec.Section section : spec.rowSections()) {
      Map<String, String> defaults = section.defaults;
      if (defaults == null) {
        continue;
      }
      for (String reference : defaults.values()) {
        if (
          String.isNotBlank(reference) &&
          reference.startsWith('$') &&
          supplied.get(reference.substring(1)) == null
        ) {
          unresolved.add(reference);
        }
      }
    }
    if (!unresolved.isEmpty()) {
      throw new DataImport.DataImportException(
        'This template has to be run from the page it belongs to. It expects ' +
          String.join(new List<String>(unresolved), ', ') +
          ', which this importer cannot supply, and the records would be created with no parent.'
      );
    }
  }

  /**
   * Stop a file whose columns have moved.
   *
   * Columns map by letter, so an inserted column shifts every heading and every row then imports
   * successfully into the wrong fields — no error, silent corruption. This is the only thing
   * standing between a reissued workbook and that.
   */
  @TestVisible
  private static void assertHeaders(
    DataImportSpec spec,
    List<List<String>> rows
  ) {
    for (DataImportSpec.Section section : spec.rowSections()) {
      if (section.expectHeader == null || section.headerRow == null) {
        continue;
      }
      Integer index = section.headerRow - 1;
      List<String> header = rows.size() > index
        ? rows[index]
        : new List<String>();
      for (String letter : section.expectHeader.keySet()) {
        Integer column = DataImportSpec.columnIndex(letter);
        String actual = DataImport.cell(header, column);
        String expected = section.expectHeader.get(letter);
        if (!actual.containsIgnoreCase(expected)) {
          throw new DataImport.DataImportException(
            'Column ' +
              letter +
              ' should read "' +
              expected +
              '" but this file has "' +
              actual +
              '". This may be a newer version of the form than the template covers.'
          );
        }
      }
    }
  }

  /** The header block, verbatim, so a reject file the same template can parse can be rebuilt. */
  @TestVisible
  private static String captureHeader(
    DataImportSpec spec,
    List<List<String>> rows
  ) {
    Integer depth = Math.min(spec.headerDepth(), rows.size());
    List<String> lines = new List<String>();
    for (Integer i = 0; i < depth; i++) {
      lines.add(DataImportWalker.encode(rows[i]));
    }
    return String.join(lines, '\n');
  }

  /**
   * Read the `cells` sections into the bindings.
   *
   * Resolved once, here, because these values sit at the top of the file and every row needs them
   * — including rows in a chunk that never sees the top of the file.
   */
  @TestVisible
  private static Map<String, Object> resolveCells(
    DataImportSpec spec,
    List<List<String>> rows,
    String existingBindingsJson
  ) {
    Map<String, Object> bindings = String.isBlank(existingBindingsJson)
      ? new Map<String, Object>()
      : (Map<String, Object>) JSON.deserializeUntyped(existingBindingsJson);

    for (DataImportSpec.Section section : spec.cellSections()) {
      if (section.cells == null) {
        continue;
      }
      for (String address : section.cells.keySet()) {
        Integer row = DataImportSpec.rowOf(address);
        Integer column = DataImportSpec.columnOf(address);
        if (row == null || column == null || rows.size() < row) {
          continue;
        }
        bindings.put(
          section.cells.get(address),
          DataImport.cell(rows[row - 1], column)
        );
      }
    }
    return bindings;
  }

  // ------------------------------------------------------------------
  // Support
  // ------------------------------------------------------------------

  /**
   * An AuraHandledException carrying a message the caller can actually read.
   *
   * The constructor alone leaves getMessage() returning "Script-thrown exception" in Apex, which
   * hides exactly the row-and-column detail these messages exist to carry.
   */
  private static AuraHandledException reportable(String message) {
    AuraHandledException error = new AuraHandledException(message);
    error.setMessage(message);
    return error;
  }

  private static Data_Import_Job__c load(Id jobId) {
    return [
      SELECT
        Id,
        Name,
        Template__c,
        File_Name__c,
        Status__c,
        Mode__c,
        Bindings__c,
        Section_Map__c,
        Header_Rows__c,
        Total_Chunks__c,
        Chunks_Processed__c,
        Rows_Read__c,
        Rows_Valid__c,
        Rows_Failed__c,
        Records_Committed__c,
        Records_Updated__c,
        Error_Count__c,
        Errors__c,
        Message__c
      FROM Data_Import_Job__c
      WHERE Id = :jobId
      LIMIT 1
    ];
  }

  /** Best-effort: the caller is already receiving the exception, so a failure here must not mask it. */
  @TestVisible
  private static void fail(Id jobId, String message) {
    try {
      update new Data_Import_Job__c(
        Id = jobId,
        Status__c = 'Failed',
        Message__c = message
      );
    } catch (Exception ignored) {
      System.debug(LoggingLevel.ERROR, 'Could not mark job failed: ' + message);
    }
  }
}
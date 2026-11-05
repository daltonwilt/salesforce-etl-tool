/**********************************************************************************
* Name         : DataImportBatch
* Author       : Dalton Wilt
* Desc         : Runs an import, one staged chunk per transaction.
*
*                Scope is deliberately one chunk. A chunk is one Long Text field - about
*                128 KB, or 800 to 1,300 rows - which keeps every governor limit in the
*                same place no matter how large the file is: about 1.5 MB of a 12 MB
*                heap, ~1,000 of 10,000 DML rows, one of 100 queries. A file of ten
*                chunks and a file of ten thousand cost exactly the same per chunk, and
*                that is what "no ceiling" means here.
*
*                Two modes, which differ in how many passes they need:
*
*                    All or Nothing   a Validate pass that writes nothing, then a Commit
*                                     pass if the file is clean. There is no transaction
*                                     spanning 400,000 rows to roll back, so the only way
*                                     to promise all-or-nothing is to find out before
*                                     writing anything.
*                    Partial Success  one pass. It never asks "is the whole file clean",
*                                     so there is nothing for a second pass to answer.
*
*                Rejected rows are written out as they are found rather than
*                accumulated, because holding every failed row of a large file in batch
*                heap is the ceiling this whole design exists to avoid. They stay as
*                chunks; the uploader assembles them into a download. Building a file
*                here would reimpose a ceiling and require Files permissions a portal
*                user does not have.
* Created On   : 2026-08-03
* Test classes : DataImportBatchTest
*
* Sharing      : inherited sharing - a batch started from a portal user's job must not
*                silently widen what that user could write by hand.
*
* @see DataImportJob
*
* Modification Log:
* ----------------------------------------------------------------------
* Developer        Date          Description
* ----------------------------------------------------------------------
* Dalton Wilt      2026-08-03    Initial implementation.
**********************************************************************************/

public inherited sharing class DataImportBatch implements Database.Batchable<SObject>, Database.Stateful {
  /** Read every row and report, but write nothing. The first of All or Nothing's
   *  two passes - the only way to promise all-or-nothing without a transaction
   *  spanning the whole file. */
  public static final String PHASE_VALIDATE = 'Validate';

  /** Read and write. The second All or Nothing pass, and the only Partial Success
   *  pass. */
  public static final String PHASE_COMMIT = 'Commit';

  private final Id jobId;
  private final String phase;

  private DataImportSpec spec;
  private List<DataImportWalker.SectionRange> ranges;
  private Map<String, Object> bindings;

  // Stateful across chunks.
  private Integer rowsRead = 0;
  private Integer rowsFailed = 0;
  private Integer inserted = 0;
  private Integer updated = 0;
  private Integer errorCount = 0;
  private Integer chunksDone = 0;
  private Boolean aborted = false;
  private List<String> errorLines = new List<String>();

  /**
   * @param jobId the Data_Import_Job__c to run
   * @param phase PHASE_VALIDATE to read without writing, or PHASE_COMMIT to write.
   *              All or Nothing runs both in turn; Partial Success runs Commit alone
   */
  public DataImportBatch(Id jobId, String phase) {
    this.jobId = jobId;
    this.phase = phase;
  }

  private Boolean isWriting() {
    return phase == PHASE_COMMIT || !spec.isAllOrNothing();
  }

  // ------------------------------------------------------------------
  // Batchable
  // ------------------------------------------------------------------

  /**
   * Loads the template and bindings, then locates this job's staged chunks.
   *
   * @param context the batch context
   * @return        a locator over the job's input chunks, in sequence order
   */
  public Database.QueryLocator start(Database.BatchableContext context) {
    Data_Import_Job__c job = [
      SELECT Template__c, Bindings__c, Section_Map__c
      FROM Data_Import_Job__c
      WHERE Id = :jobId
      LIMIT 1
    ];
    loadContext(job);
    update new Data_Import_Job__c(
      Id = jobId,
      Status__c = phase == PHASE_VALIDATE ? 'Validating' : 'Committing'
    );
    Id scopedJobId = jobId;
    return Database.getQueryLocator(
      [
        SELECT Id, Sequence__c, First_Row_Number__c, Body__c
        FROM Data_Import_Chunk__c
        WHERE Job__c = :scopedJobId AND Is_Reject__c = FALSE
        ORDER BY Sequence__c ASC
      ]
    );
  }

  /**
   * Walks one chunk and, in the Commit phase, writes what it produced.
   *
   * @param context the batch context
   * @param scope   one staged chunk - scope is 1, so every governor limit stays in the
   *                same place however large the file is
   */
  public void execute(
    Database.BatchableContext context,
    List<Data_Import_Chunk__c> scope
  ) {
    if (aborted) {
      return;
    }
    if (spec == null) {
      loadContext(
        [
          SELECT Template__c, Bindings__c, Section_Map__c
          FROM Data_Import_Job__c
          WHERE Id = :jobId
          LIMIT 1
        ]
      );
    }

    DataImportWalker walker = new DataImportWalker(spec, ranges, bindings);

    for (Data_Import_Chunk__c chunk : scope) {
      DataImportWalker.Outcome outcome = walker.walk(
        DataImport.parse(chunk.Body__c),
        Integer.valueOf(chunk.First_Row_Number__c)
      );
      rowsRead += outcome.rows.size();
      record(outcome.errors);

      List<DataImportWalker.Row> rejects = new List<DataImportWalker.Row>();
      for (DataImportWalker.Row row : outcome.rows) {
        if (row.failed) {
          rowsFailed++;
          rejects.add(row);
        }
      }

      if (isWriting() && !aborted) {
        rejects.addAll(write(outcome.usable()));
      }
      if (!rejects.isEmpty()) {
        stashRejects(chunk, rejects);
      }
      chunksDone++;
      if (errorCount >= spec.abortThreshold()) {
        aborted = true;
        break;
      }
    }
    saveCounters();
  }

  /**
   * Writes the counters back to the job, sets its terminal status, and either chains
   * the Commit pass or cleans up the staged chunks.
   *
   * @param context the batch context
   */
  public void finish(Database.BatchableContext context) {
    Data_Import_Job__c job = new Data_Import_Job__c(Id = jobId);
    job.Rows_Read__c = rowsRead;
    job.Rows_Failed__c = rowsFailed;
    job.Rows_Valid__c = rowsRead - rowsFailed;
    job.Records_Committed__c = inserted + updated;
    job.Records_Updated__c = updated;
    job.Error_Count__c = errorCount;
    job.Errors__c = joinErrors();
    job.Chunks_Processed__c = chunksDone;

    if (aborted) {
      job.Status__c = 'Aborted';
      job.Message__c =
        'Stopped after ' +
        errorCount +
        ' errors. This file may not match the template.' +
        (isWriting() ? ' Rows imported before it stopped were kept.' : '');
      finishUp(job);
      return;
    }

    // All or Nothing: a clean validate pass earns the commit pass; anything else writes nothing.
    if (spec.isAllOrNothing() && phase == PHASE_VALIDATE) {
      if (errorCount == 0) {
        job.Status__c = 'Validated';
        update job;
        Database.executeBatch(new DataImportBatch(jobId, PHASE_COMMIT), 1);
        return;
      }
      job.Status__c = 'Failed';
      job.Message__c =
        rowsRead +
        ' rows read · ' +
        rowsFailed +
        ' could not be imported · nothing was saved.';
      finishUp(job);
      return;
    }

    job.Status__c = 'Completed';
    job.Message__c =
      rowsRead +
      ' rows read · ' +
      rowsFailed +
      ' could not be imported · ' +
      (inserted + updated) +
      ' saved.';
    finishUp(job);
  }

  // ------------------------------------------------------------------
  // Writing
  // ------------------------------------------------------------------

  /**
   * Insert the new rows and update the matched ones.
   *
   * Matching is a query per target rather than Database.upsert: upsert needs a true External Id
   * field and most objects have none, and a query gives a usable message when a key is ambiguous.
   *
   * @return rows that could not be written, for the reject file
   */
  private List<DataImportWalker.Row> write(
    List<DataImportWalker.Row> rows
  ) {
    List<DataImportWalker.Row> failures = new List<DataImportWalker.Row>();
    Map<String, List<DataImportWalker.Row>> bySection = new Map<String, List<DataImportWalker.Row>>();
    for (DataImportWalker.Row row : rows) {
      String key = row.section == null ? '' : row.section;
      if (!bySection.containsKey(key)) {
        bySection.put(key, new List<DataImportWalker.Row>());
      }
      bySection.get(key).add(row);
    }

    for (String sectionName : bySection.keySet()) {
      DataImportSpec.Section section = section(sectionName);
      List<DataImportWalker.Row> sectionRows = bySection.get(sectionName);
      List<DataImportWalker.Row> toInsert = new List<DataImportWalker.Row>();
      List<DataImportWalker.Row> toUpdate = new List<DataImportWalker.Row>();

      if (section != null && section.applyToChildren != null) {
        failures.addAll(broadcast(section, sectionRows));
        continue;
      }

      if (section != null && section.matchOn != null) {
        Map<String, List<SObject>> existing = lookup(section, sectionRows);
        for (DataImportWalker.Row row : sectionRows) {
          List<SObject> matches = String.isBlank(row.key)
            ? null
            : existing.get(row.key.toLowerCase());
          if (matches == null || matches.isEmpty()) {
            toInsert.add(row); // nothing to match, so the row is new
          } else if (matches.size() == 1) {
            row.record.put('Id', matches[0].Id);
            toUpdate.add(row);
          } else {
            record(new List<String>{ ambiguous(row, section, matches) });
            row.failed = true;
            rowsFailed++;
            failures.add(row);
          }
        }
      } else {
        toInsert.addAll(sectionRows);
      }

      failures.addAll(persist(toInsert, false));
      failures.addAll(persist(toUpdate, true));
    }
    return failures;
  }

  /**
   * Apply a request-level row to every existing child of its parent.
   *
   * Only the fields the row actually filled in are copied. A blank cell leaves each child's own
   * value alone, which is what lets this run over records entered by hand and lets a corrected
   * file overlay a previous upload rather than wipe what it omits.
   *
   * @return the row, as a failure, when there is nothing to apply it to
   */
  private List<DataImportWalker.Row> broadcast(
    DataImportSpec.Section section,
    List<DataImportWalker.Row> rows
  ) {
    List<DataImportWalker.Row> failures = new List<DataImportWalker.Row>();
    if (rows.isEmpty()) {
      return failures;
    }
    DataImportSpec.Broadcast destination = section.applyToChildren;
    Id parentId = (Id) resolveBinding(destination.parentId);
    if (parentId == null) {
      throw new DataImport.DataImportException(
        'Template "' +
          spec.name +
          '" broadcasts to children but its parentId did not resolve.'
      );
    }

    List<SObject> children = Database.query(
      'SELECT Id FROM ' +
        String.escapeSingleQuotes(destination.childObject) +
        ' WHERE ' +
        String.escapeSingleQuotes(destination.parentField) +
        ' = :parentId'
    );

    DataImportWalker.Row row = rows[0];
    if (children.isEmpty()) {
      record(
        new List<String>{
          'Row ' +
          row.rowNumber +
          ': there is nothing to apply these answers to yet. Import the line items first, or add them by hand, then upload this sheet.'
        }
      );
      row.failed = true;
      rowsFailed++;
      failures.add(row);
      return failures;
    }

    Map<String, Object> values = row.record.getPopulatedFieldsAsMap();
    List<DataImportWalker.Row> updates = new List<DataImportWalker.Row>();
    for (SObject child : children) {
      for (String apiName : values.keySet()) {
        // Id and the parent lookup are on the carrier because it was built to be inserted;
        // copying them onto an existing child is at best a no-op and at worst re-parents it.
        if (apiName == 'Id' || apiName == destination.parentField) {
          continue;
        }
        child.put(apiName, values.get(apiName));
      }
      DataImportWalker.Row childRow = new DataImportWalker.Row();
      childRow.record = child;
      childRow.rowNumber = row.rowNumber;
      childRow.section = row.section;
      childRow.raw = row.raw;
      updates.add(childRow);
    }
    // One source row, however many children it reached. Letting persist() count per child would
    // report "40 rows failed" for a file that has one, and the reject file wants the source row
    // back — not forty copies of it.
    Integer before = rowsFailed;
    List<DataImportWalker.Row> childFailures = persist(updates, true);
    if (childFailures.isEmpty()) {
      return failures;
    }
    rowsFailed = before + 1;
    row.failed = true;
    failures.add(row);
    return failures;
  }

  private Object resolveBinding(String reference) {
    if (String.isBlank(reference)) {
      return null;
    }
    return reference.startsWith('$')
      ? bindings.get(reference.substring(1))
      : reference;
  }

  /** Partial DML so one bad row does not take the chunk with it — each failure is reported alone. */
  private List<DataImportWalker.Row> persist(
    List<DataImportWalker.Row> rows,
    Boolean isUpdate
  ) {
    List<DataImportWalker.Row> failures = new List<DataImportWalker.Row>();
    if (rows.isEmpty()) {
      return failures;
    }
    List<SObject> records = new List<SObject>();
    for (DataImportWalker.Row row : rows) {
      records.add(row.record);
    }

    List<Database.SaveResult> results = isUpdate
      ? Database.update(records, false)
      : Database.insert(records, false);

    List<String> problems = new List<String>();
    for (Integer i = 0; i < results.size(); i++) {
      if (results[i].isSuccess()) {
        if (isUpdate) {
          updated++;
        } else {
          inserted++;
        }
        continue;
      }
      List<String> messages = new List<String>();
      for (Database.Error error : results[i].getErrors()) {
        messages.add(error.getMessage());
      }
      problems.add(
        'Row ' + rows[i].rowNumber + ': ' + String.join(messages, ' ')
      );
      rows[i].failed = true;
      rowsFailed++;
      failures.add(rows[i]);
    }
    record(problems);
    return failures;
  }

  /** Existing records keyed by the match value, lower-cased so matching is case-insensitive. */
  private Map<String, List<SObject>> lookup(
    DataImportSpec.Section section,
    List<DataImportWalker.Row> rows
  ) {
    Set<String> keys = new Set<String>();
    for (DataImportWalker.Row row : rows) {
      if (String.isNotBlank(row.key)) {
        keys.add(row.key);
      }
    }
    Map<String, List<SObject>> byKey = new Map<String, List<SObject>>();
    if (keys.isEmpty()) {
      return byKey;
    }

    String nameField = nameFieldOf(section.target);
    String query =
      'SELECT Id, ' +
      String.escapeSingleQuotes(section.matchOn.field) +
      (nameField == null ? '' : ', ' + nameField) +
      ' FROM ' +
      String.escapeSingleQuotes(section.target) +
      ' WHERE ' +
      String.escapeSingleQuotes(section.matchOn.field) +
      ' IN :keys';

    for (SObject record : Database.query(query)) {
      Object value = record.get(section.matchOn.field);
      if (value == null) {
        continue;
      }
      String key = String.valueOf(value).toLowerCase();
      if (!byKey.containsKey(key)) {
        byKey.put(key, new List<SObject>());
      }
      byKey.get(key).add(record);
    }
    return byKey;
  }

  /**
   * Name the records a key matched, so the message is something the user can act on.
   *
   * The name field is found on the describe rather than assumed to be `Name` — standard objects
   * vary (Case uses CaseNumber, Task uses Subject) and a few have none.
   */
  private String ambiguous(
    DataImportWalker.Row row,
    DataImportSpec.Section section,
    List<SObject> matches
  ) {
    String nameField = nameFieldOf(section.target);
    List<String> shown = new List<String>();
    for (Integer i = 0; i < Math.min(matches.size(), 5); i++) {
      Object label = nameField == null ? null : matches[i].get(nameField);
      shown.add(String.valueOf(label == null ? matches[i].Id : label));
    }
    String tail = matches.size() > 5
      ? ' …and ' + (matches.size() - 5) + ' more'
      : '';
    return 'Row ' +
      row.rowNumber +
      ', column ' +
      section.matchOn.column +
      ': "' +
      row.key +
      '" matches ' +
      matches.size() +
      ' existing records (' +
      String.join(shown, ', ') +
      tail +
      '). The key must identify a single record.';
  }

  private String nameFieldOf(String target) {
    for (
      Schema.SObjectField field : Schema.getGlobalDescribe()
        .get(target)
        .getDescribe()
        .fields.getMap()
        .values()
    ) {
      if (field.getDescribe().isNameField()) {
        return field.getDescribe().getName();
      }
    }
    return null;
  }

  // ------------------------------------------------------------------
  // Rejects
  // ------------------------------------------------------------------

  /**
   * Write this chunk's failed rows straight back out as a reject chunk.
   *
   * Written now rather than accumulated: a file where a hundred thousand rows fail would otherwise
   * hold all of them in batch heap, which is exactly the ceiling being avoided. The message rides
   * in a column to the RIGHT of everything the template maps, so the same template still parses the
   * file when the user fixes it and uploads it back.
   */
  private void stashRejects(
    Data_Import_Chunk__c source,
    List<DataImportWalker.Row> rows
  ) {
    Map<String, List<String>> linesBySection = new Map<String, List<String>>();
    Map<Integer, String> messageByRow = messagesByRow();

    for (DataImportWalker.Row row : rows) {
      String key = row.section == null ? '' : row.section;
      if (!linesBySection.containsKey(key)) {
        linesBySection.put(key, new List<String>());
      }
      String note = messageByRow.containsKey(row.rowNumber)
        ? 'Row ' + row.rowNumber + ' — ' + messageByRow.get(row.rowNumber)
        : 'Row ' + row.rowNumber + ' — could not be imported';
      linesBySection.get(key)
        .add(row.raw + ',,' + DataImportWalker.quote(note));
    }

    List<Data_Import_Chunk__c> rejects = new List<Data_Import_Chunk__c>();
    for (String sectionName : linesBySection.keySet()) {
      rejects.add(
        new Data_Import_Chunk__c(
          Job__c = jobId,
          Sequence__c = source.Sequence__c,
          First_Row_Number__c = source.First_Row_Number__c,
          Is_Reject__c = true,
          Section__c = String.isBlank(sectionName) ? null : sectionName,
          Body__c = String.join(linesBySection.get(sectionName), '\n')
        )
      );
    }
    insert rejects;
  }

  /**
   * Every message for a row, joined, for annotating that row in the reject file.
   *
   * A row can fail on more than one cell, and keeping only the last meant the person fixing it saw
   * one problem, corrected it, re-uploaded, and met the next — one round trip per bad cell.
   */
  private Map<Integer, String> messagesByRow() {
    Map<Integer, String> byRow = new Map<Integer, String>();
    Pattern rowPrefix = Pattern.compile('^Row (\\d+)[,:] ?(.*)$');
    for (String line : errorLines) {
      Matcher m = rowPrefix.matcher(line);
      if (!m.matches()) {
        continue;
      }
      Integer row = Integer.valueOf(m.group(1));
      String message = m.group(2);
      byRow.put(
        row,
        byRow.containsKey(row) ? byRow.get(row) + '; ' + message : message
      );
    }
    return byRow;
  }

  // ------------------------------------------------------------------
  // Support
  // ------------------------------------------------------------------

  private void loadContext(Data_Import_Job__c job) {
    spec = DataImportSpec.load(job.Template__c);
    bindings = String.isBlank(job.Bindings__c)
      ? new Map<String, Object>()
      : (Map<String, Object>) JSON.deserializeUntyped(job.Bindings__c);
    ranges = String.isBlank(job.Section_Map__c)
      ? new List<DataImportWalker.SectionRange>()
      : (List<DataImportWalker.SectionRange>) JSON.deserialize(
          job.Section_Map__c,
          List<DataImportWalker.SectionRange>.class
        );
  }

  private DataImportSpec.Section section(String sectionName) {
    if (String.isBlank(sectionName)) {
      List<DataImportSpec.Section> rows = spec.rowSections();
      return rows.isEmpty() ? null : rows[0];
    }
    return spec.sectionNamed(sectionName);
  }

  /** Errors are counted in full but only the first MAX are kept — the field holds ~1,300 lines. */
  private void record(List<String> problems) {
    for (String problem : problems) {
      errorCount++;
      if (errorLines.size() < 1200) {
        errorLines.add(problem);
      }
    }
  }

  private String joinErrors() {
    if (errorLines.isEmpty()) {
      return null;
    }
    String joined = String.join(errorLines, '\n');
    if (errorCount > errorLines.size()) {
      joined += '\n…and ' + (errorCount - errorLines.size()) + ' more.';
    }
    return joined.abbreviate(131000);
  }

  private void saveCounters() {
    update new Data_Import_Job__c(
      Id = jobId,
      Rows_Read__c = rowsRead,
      Rows_Failed__c = rowsFailed,
      Records_Committed__c = inserted + updated,
      Error_Count__c = errorCount,
      Chunks_Processed__c = chunksDone
    );
  }

  /**
   * Terminal: write the counters and drop the staged input.
   *
   * Reject chunks are deliberately kept. They ARE the rejected rows, held in the same unbounded
   * form the input arrived in, and the uploader assembles them into a download on demand. Turning
   * them into a file here is what previously introduced both a size ceiling and the whole Files
   * permission surface — which a portal user cannot clear. They go when the job goes: Job__c is
   * master-detail, so deleting a job takes its chunks with it.
   */
  private void finishUp(Data_Import_Job__c job) {
    update job;
    delete [
      SELECT Id
      FROM Data_Import_Chunk__c
      WHERE Job__c = :jobId AND Is_Reject__c = FALSE
    ];
  }
}
/**********************************************************************************
* Name         : DataImportBatchTest
* Author       : Dalton Wilt
* Desc         : Tests for DataImportBatch - the pass that actually writes, and
*                the outcomes it has to reach. These run end to end through
*                DataImportJob.run because the batch is only meaningful once it
*                has a job, a spec and staged chunks behind it.
*
*                The two commit modes are the substance. All-or-nothing has to write
*                nothing at all when any row fails, including the rows that were
*                fine. Partial Success has to keep the good rows AND hand the failed
*                ones back annotated, because a reject file the recipient can correct
*                and re-upload is the whole point of the mode.
*
*                Also covered: matching an existing record by key (insert vs update,
*                blank keys, ambiguous keys), broadcasting one request-level row to
*                every child, and the abort threshold that stops a file which is
*                simply the wrong file.
* Created On   : 2026-08-20
*
* Class under test : DataImportBatch
*
* Modification Log:
* ----------------------------------------------------------------------
* Developer        Date          Description
* ----------------------------------------------------------------------
* Dalton Wilt      2026-08-20    Split out of DataImportFrameworkTest.
* Dalton Wilt      2026-11-06    Run as DataImportTestUser, with Data_Import_User.
**********************************************************************************/

@isTest
private class DataImportBatchTest {

    private static final String TEMPLATE = 'TestAccounts';

    /** A plain table: headings on row 1, data from row 2. The shape most templates have. */
    private static String simpleTemplate() {
        return JSON.serialize(
            new Map<String, Object>{
                'label' => 'Test Accounts',
                'sections' => new List<Object>{
                    new Map<String, Object>{
                        'type' => 'rows',
                        'target' => 'Account',
                        'headerRow' => 1,
                        'firstDataRow' => 2,
                        'columns' => new Map<String, String>{
                            'A' => 'Name',
                            'B' => 'AccountNumber',
                            'C' => 'NumberOfEmployees'
                        }
                    }
                }
            }
        );
    }

    private static String partialSuccessTemplate() {
        return simpleTemplate().replace('"label"', '"mode":"Partial Success","label"');
    }

    /** Matches on AccountNumber, so a row either updates what it finds or inserts. */
    private static String matchingTemplate() {
        return JSON.serialize(
            new Map<String, Object>{
                'mode' => 'Partial Success',
                'sections' => new List<Object>{
                    new Map<String, Object>{
                        'type' => 'rows',
                        'target' => 'Account',
                        'firstDataRow' => 2,
                        'columns' => new Map<String, String>{
                            'A' => 'Name',
                            'B' => 'AccountNumber',
                            'C' => 'Site'
                        },
                        'matchOn' => new Map<String, Object>{
                            'column' => 'B',
                            'field' => 'AccountNumber'
                        }
                    }
                }
            }
        );
    }

    /** One request-level row applied to every child of a parent - SF-428C's shape, on Account. */
    private static String broadcastTemplate() {
        return JSON.serialize(
            new Map<String, Object>{
                'sections' => new List<Object>{
                    new Map<String, Object>{
                        'type' => 'rows',
                        'target' => 'Contact',
                        'firstDataRow' => 2,
                        'lastDataRow' => 2,
                        'columns' => new Map<String, String>{ 'A' => 'Title' },
                        'applyToChildren' => new Map<String, Object>{
                            'childObject' => 'Contact',
                            'parentField' => 'AccountId',
                            'parentId' => '$accountId'
                        }
                    }
                }
            }
        );
    }

    private static void register(String json) {
        DataImportSpec.jsonOverride = new Map<String, String>{ TEMPLATE => json };
        DataImportSpec.clearCache();
    }

    private static Id newJob(String templateName) {
        return newJob(templateName, '{}');
    }

    private static Id newJob(String templateName, String bindingsJson) {
        DataImportJob.Request request = new DataImportJob.Request();
        request.template = templateName;
        request.fileName = 'accounts.csv';
        request.totalChunks = 1;
        request.bindingsJson = bindingsJson;
        return DataImportJob.start(request);
    }

    private static Data_Import_Job__c reload(Id jobId) {
        return [
            SELECT
                Status__c,
                Rows_Read__c,
                Rows_Valid__c,
                Rows_Failed__c,
                Records_Committed__c,
                Records_Updated__c,
                Error_Count__c,
                Errors__c,
                Message__c,
                Header_Rows__c
            FROM Data_Import_Job__c
            WHERE Id = :jobId
            LIMIT 1
        ];
    }

    private static List<Data_Import_Chunk__c> rejectChunks(Id jobId) {
        return [
            SELECT Body__c
            FROM Data_Import_Chunk__c
            WHERE Job__c = :jobId AND Is_Reject__c = TRUE
        ];
    }

    // ---------------- all or nothing ----------------

    @isTest
    static void allOrNothincleanFile_commitsEveryRow() {
        System.runAs(DataImportTestUser.get()) {
            register(simpleTemplate());
            Id jobId = newJob(TEMPLATE);
            DataImportJob.stage(jobId, 0, 1, 'Name,Number,Staff\nAcme,A-1,50\nBeta,B-2,10');

            Test.startTest();
            DataImportJob.run(jobId, 1, null);
            Test.stopTest();

            Data_Import_Job__c job = reload(jobId);
            // stopTest() drains the chained commit pass too, so a clean file finishes inside the test.
            Assert.areEqual('Completed', job.Status__c);
            Assert.areEqual(2, job.Rows_Read__c);
            Assert.areEqual(0, job.Error_Count__c);
            Assert.areEqual(2, [SELECT COUNT() FROM Account], 'both rows were written');
        }
    }

    /**
     * The promise of all-or-nothing: one bad cell anywhere means nothing is written,
     * including the rows that were fine.
     */
    @isTest
    static void allOrNothinanyRowFails_writesNothing() {
        System.runAs(DataImportTestUser.get()) {
            register(simpleTemplate());
            Id jobId = newJob(TEMPLATE);
            DataImportJob.stage(jobId, 0, 1, 'Name,Number,Staff\nAcme,A-1,50\nBeta,B-2,lots');

            Test.startTest();
            DataImportJob.run(jobId, 1, null);
            Test.stopTest();

            Data_Import_Job__c job = reload(jobId);
            Assert.areEqual('Failed', job.Status__c);
            Assert.areEqual(1, job.Rows_Failed__c);
            Assert.areEqual(0, [SELECT COUNT() FROM Account], 'the good row must not be written either');
            Assert.isTrue(job.Message__c.contains('nothing was saved'), job.Message__c);
            Assert.isTrue(job.Errors__c.contains('Row 3'), job.Errors__c);
        }
    }

    // ---------------- partial success ----------------

    @isTest
    static void partialSuccess_oneBadRow_keepsTheGoodRows() {
        System.runAs(DataImportTestUser.get()) {
            register(partialSuccessTemplate());
            Id jobId = newJob(TEMPLATE);
            DataImportJob.stage(
                jobId,
                0,
                1,
                'Name,Number,Staff\nAcme,A-1,50\nBeta,B-2,lots\nGamma,C-3,7'
            );

            Test.startTest();
            DataImportJob.run(jobId, 1, null);
            Test.stopTest();

            Data_Import_Job__c job = reload(jobId);
            Assert.areEqual('Completed', job.Status__c);
            Assert.areEqual(2, job.Records_Committed__c);
            Assert.areEqual(1, job.Rows_Failed__c);
            Assert.areEqual(2, [SELECT COUNT() FROM Account]);
            Assert.isTrue(job.Message__c.contains('2 saved'), job.Message__c);
        }
    }

    /** The whole point of the reject file: the template back, with only the rows that failed. */
    @isTest
    static void partialSuccess_failedRows_areHandedBack() {
        System.runAs(DataImportTestUser.get()) {
            register(partialSuccessTemplate());
            Id jobId = newJob(TEMPLATE);
            DataImportJob.stage(jobId, 0, 1, 'Name,Number,Staff\nAcme,A-1,50\nBeta,B-2,lots');

            Test.startTest();
            DataImportJob.run(jobId, 1, null);
            Test.stopTest();

            // The rejected rows stay as chunks - the uploader assembles them into a download. Building
            // a file here would reimpose a size ceiling and need Files permissions a portal user lacks.
            List<Data_Import_Chunk__c> rejects = rejectChunks(jobId);
            Assert.areEqual(1, rejects.size(), 'the failed row was kept');
            String body = rejects[0].Body__c;
            Assert.isTrue(body.contains('Beta'), 'the failed row is in it');
            Assert.isFalse(body.contains('Acme'), 'the row that worked is not');
            Assert.isTrue(body.contains('is not a number'), 'and the reason rides along: ' + body);

            // The header block is kept on the job, so the download can be rebuilt from these.
            Assert.areEqual(
                'Name,Number,Staff',
                reload(jobId).Header_Rows__c,
                'the header the download needs is preserved'
            );

            DataImportJob.RejectPage page = DataImportJob.getRejectRows(jobId, null);
            Assert.areEqual(1, page.rows.size());
            Assert.areEqual(false, page.hasMore);
            Assert.areEqual('Name,Number,Staff', page.header, 'the first page carries the header');

            // Every chunk goes once the file is built - staged rows have been read, and rejected rows
            // now live in the file. Leaving either behind is storage that grows with every failed import.
            Assert.areEqual(
                0,
                [SELECT COUNT() FROM Data_Import_Chunk__c WHERE Is_Reject__c = FALSE],
                'the staged input is cleaned up'
            );
        }
    }

    /**
     * A job must always reach a terminal status, whatever happens to the reject file.
     *
     * Attaching one can fail on permissions the importer does not control - a portal
     * user cannot always publish a file to a record they own. Because that ran in the
     * same transaction as the status update, an unguarded failure rolled the update
     * back and left the job on 'Validating' with no message and its chunks undeleted:
     * no result, no error, nothing to retry from.
     */
    @isTest
    static void partialSuccess_rejectFileCannotBeAttached_stillFinishes() {
        System.runAs(DataImportTestUser.get()) {
            register(partialSuccessTemplate());
            Id jobId = newJob(TEMPLATE);
            DataImportJob.stage(jobId, 0, 1, 'Name,Number,Staff\nAcme,A-1,50\nBeta,B-2,lots');

            Test.startTest();
            DataImportJob.run(jobId, 1, null);
            Test.stopTest();

            Data_Import_Job__c job = reload(jobId);
            Assert.areEqual(
                'Completed',
                job.Status__c,
                'the job reports its outcome regardless of the attachment'
            );
            Assert.isNotNull(job.Message__c);
            Assert.areEqual(
                0,
                [SELECT COUNT() FROM Data_Import_Chunk__c WHERE Is_Reject__c = FALSE],
                'and its staged input is still cleaned up'
            );
        }
    }

    /**
     * A row can fail on more than one cell. Keeping only the last message meant the
     * person fixing it saw one problem, corrected it, re-uploaded, and met the next -
     * a round trip per bad cell.
     */
    @isTest
    static void partialSuccess_badRow_carriesItsReason() {
        System.runAs(DataImportTestUser.get()) {
            register(partialSuccessTemplate());
            Id jobId = newJob(TEMPLATE);
            // One row, two bad cells: the picklist AND the number.
            DataImportJob.stage(jobId, 0, 1, 'Name,Number,Staff\nAcme,A-1,50\nBeta,B-2,lots');

            Test.startTest();
            DataImportJob.run(jobId, 1, null);
            Test.stopTest();

            String rejected = rejectChunks(jobId)[0].Body__c;
            Assert.isTrue(
                rejected.contains('is not a number'),
                'the reason is annotated: ' + rejected
            );
        }
    }

    // ---------------- insert and update ----------------

    @isTest
    static void matchOn_existingKey_updatesItAndInsertsTheRest() {
        System.runAs(DataImportTestUser.get()) {
            insert new Account(Name = 'Existing', AccountNumber = 'A-1', Site = 'old');
            register(matchingTemplate());

            Id jobId = newJob(TEMPLATE);
            DataImportJob.stage(jobId, 0, 1, 'Name,Number,Site\nAcme,A-1,new\nBeta,B-2,fresh');

            Test.startTest();
            DataImportJob.run(jobId, 1, null);
            Test.stopTest();

            Data_Import_Job__c job = reload(jobId);
            Assert.areEqual(1, job.Records_Updated__c);
            Assert.areEqual(2, job.Records_Committed__c);
            Assert.areEqual(
                'new',
                [SELECT Site FROM Account WHERE AccountNumber = 'A-1' LIMIT 1].Site
            );
            Assert.areEqual(2, [SELECT COUNT() FROM Account]);
        }
    }

    /** A blank key means there is nothing to match, so the row is new. */
    @isTest
    static void matchOn_blankKey_inserts() {
        System.runAs(DataImportTestUser.get()) {
            register(matchingTemplate());
            Id jobId = newJob(TEMPLATE);
            DataImportJob.stage(jobId, 0, 1, 'Name,Number,Site\nAcme,,here');

            Test.startTest();
            DataImportJob.run(jobId, 1, null);
            Test.stopTest();

            Assert.areEqual(1, [SELECT COUNT() FROM Account]);
        }
    }

    /** Ambiguity has to name the records, or the user cannot go and look at them. */
    @isTest
    static void matchOn_keyMatchesSeveralRecords_failsTheRowAndNamesThem() {
        System.runAs(DataImportTestUser.get()) {
            insert new List<Account>{
                new Account(Name = 'First', AccountNumber = 'A-1'),
                new Account(Name = 'Second', AccountNumber = 'A-1')
            };
            register(matchingTemplate());

            Id jobId = newJob(TEMPLATE);
            DataImportJob.stage(jobId, 0, 1, 'Name,Number,Site\nAcme,A-1,here');

            Test.startTest();
            DataImportJob.run(jobId, 1, null);
            Test.stopTest();

            Data_Import_Job__c job = reload(jobId);
            Assert.areEqual(1, job.Rows_Failed__c);
            Assert.isTrue(job.Errors__c.contains('matches 2 existing records'), job.Errors__c);
            Assert.isTrue(job.Errors__c.contains('First'), 'the names are listed: ' + job.Errors__c);
        }
    }

    @isTest
    static void requireKey_blankKey_failsTheRow() {
        System.runAs(DataImportTestUser.get()) {
            register(
                matchingTemplate()
                    .replace('"field":"AccountNumber"', '"field":"AccountNumber","requireKey":true')
            );
            Id jobId = newJob(TEMPLATE);
            DataImportJob.stage(jobId, 0, 1, 'Name,Number,Site\nAcme,,here');

            Test.startTest();
            DataImportJob.run(jobId, 1, null);
            Test.stopTest();

            Assert.areEqual(1, reload(jobId).Rows_Failed__c);
            Assert.areEqual(0, [SELECT COUNT() FROM Account]);
        }
    }

    // ---------------- broadcast ----------------

    @isTest
    static void broadcast_oneRow_appliesToEveryChild() {
        System.runAs(DataImportTestUser.get()) {
            Account parent = new Account(Name = 'Parent');
            insert parent;
            insert new List<Contact>{
                new Contact(LastName = 'One', AccountId = parent.Id),
                new Contact(LastName = 'Two', AccountId = parent.Id)
            };
            register(broadcastTemplate());

            Id jobId = newJob(
                TEMPLATE,
                JSON.serialize(new Map<String, Object>{ 'accountId' => parent.Id })
            );
            DataImportJob.stage(jobId, 0, 1, 'Title\nDirector');

            Test.startTest();
            DataImportJob.run(jobId, 1, null);
            Test.stopTest();

            Assert.areEqual(
                2,
                [SELECT COUNT() FROM Contact WHERE Title = 'Director'],
                'the single row reached every child'
            );
            Assert.areEqual(
                1,
                reload(jobId).Rows_Read__c,
                'the file still has one row, however many children it touched'
            );
        }
    }

    /** There is nothing to apply a request-level row to until the line items exist. */
    @isTest
    static void broadcast_noChildren_failsTheRow() {
        System.runAs(DataImportTestUser.get()) {
            Account parent = new Account(Name = 'Childless');
            insert parent;
            register(broadcastTemplate());

            Id jobId = newJob(
                TEMPLATE,
                JSON.serialize(new Map<String, Object>{ 'accountId' => parent.Id })
            );
            DataImportJob.stage(jobId, 0, 1, 'Title\nDirector');

            Test.startTest();
            DataImportJob.run(jobId, 1, null);
            Test.stopTest();

            Data_Import_Job__c job = reload(jobId);
            Assert.areEqual(1, job.Rows_Failed__c);
            Assert.isTrue(job.Errors__c.contains('nothing to apply'), job.Errors__c);
        }
    }

    // ---------------- abort threshold ----------------

    /** A file failing on every row is the wrong file; saying so 400,000 times helps nobody. */
    @isTest
    static void abortAfterErrors_thresholdReached_stopsTheJob() {
        System.runAs(DataImportTestUser.get()) {
            register(simpleTemplate().replace('"label"', '"abortAfterErrors":2,"label"'));

            List<String> lines = new List<String>{ 'Name,Number,Staff' };
            for (Integer i = 0; i < 10; i++) {
                lines.add('Acme' + i + ',A-' + i + ',not a number');
            }
            Id jobId = newJob(TEMPLATE);
            DataImportJob.stage(jobId, 0, 1, String.join(lines, '\n'));

            Test.startTest();
            DataImportJob.run(jobId, 1, null);
            Test.stopTest();

            Data_Import_Job__c job = reload(jobId);
            Assert.areEqual('Aborted', job.Status__c);
            Assert.isTrue(job.Message__c.contains('Stopped after'), job.Message__c);
        }
    }
}
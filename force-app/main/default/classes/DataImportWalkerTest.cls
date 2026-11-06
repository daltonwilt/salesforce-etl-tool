/**********************************************************************************
* Name         : DataImportWalkerTest
* Author       : Dalton Wilt
* Desc         : Tests for DataImportWalker - turning parsed rows into records,
*                folding sideways Yes/No option columns into a single field, routing
*                rows to the section that claims them, and re-encoding a row for the
*                reject file.
*
*                Most tests drive the walker directly, which is what makes the
*                chunking claim testable: a chunk from the middle of a file carries
*                no headings and must still number its rows correctly.
*
*                The group tests are the exception - they run a whole job through
*                DataImportJob.run, because a folded value only becomes observable
*                once it reaches a record. They are still walker tests; the job is
*                just the shortest path to the assertion.
*
*                Written against Account, and against a text field rather than a
*                multi-select, for the reason the framework header gives: the claim
*                is that it loads any object, and Account carries no multi-select.
*                What the platform does with the joined string is its own business.
* Created On   : 2026-08-20
*
* Class under test : DataImportWalker
*
* Modification Log:
* ----------------------------------------------------------------------
* Developer        Date          Description
* ----------------------------------------------------------------------
* Dalton Wilt      2026-08-20    Split out of DataImportFrameworkTest.
* Dalton Wilt      2026-11-06    Run as DataImportTestUser, with Data_Import_User.
* Dalton Wilt      2026-11-06    Cover the remaining DataImportWalker paths.
**********************************************************************************/

@isTest
private class DataImportWalkerTest {

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

    /**
     * A multi-select laid out sideways - a column per option with Yes or No under it,
     * which is how every SF-428 sheet asks one. Each Yes contributes its value; a No
     * contributes nothing.
     */
    private static String groupedTemplate(String mappedField) {
        return JSON.serialize(
            new Map<String, Object>{
                'sections' => new List<Object>{
                    new Map<String, Object>{
                        'type' => 'rows',
                        'target' => 'Account',
                        'firstDataRow' => 1,
                        'columns' => new Map<String, String>{ 'A' => mappedField },
                        'groups' => new List<Object>{
                            new Map<String, Object>{
                                'field' => 'Description',
                                'options' => new Map<String, String>{
                                    'B' => 'Alpha',
                                    'C' => 'Beta'
                                }
                            }
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

    /** The walker as a chunk gets it: a loaded spec, no resolved ranges, no bindings. */
    private static DataImportWalker walkerFor(String templateName) {
        return new DataImportWalker(
            DataImportSpec.load(templateName),
            new List<DataImportWalker.SectionRange>(),
            new Map<String, Object>()
        );
    }

    private static DataImportWalker walkerFor(String templateName, String rangesJson) {
        List<DataImportWalker.SectionRange> ranges = (List<DataImportWalker.SectionRange>) JSON.deserialize(
            rangesJson,
            List<DataImportWalker.SectionRange>.class
        );
        return new DataImportWalker(
            DataImportSpec.load(templateName),
            ranges,
            new Map<String, Object>()
        );
    }

    private static Id newJob(String templateName) {
        DataImportJob.Request request = new DataImportJob.Request();
        request.template = templateName;
        request.fileName = 'accounts.csv';
        request.totalChunks = 1;
        request.bindingsJson = '{}';
        return DataImportJob.start(request);
    }

    private static Data_Import_Job__c reload(Id jobId) {
        return [
            SELECT Records_Committed__c, Rows_Failed__c, Errors__c
            FROM Data_Import_Job__c
            WHERE Id = :jobId
            LIMIT 1
        ];
    }

    // ---------------- walk ----------------

    @isTest
    static void walk_dataRows_buildsARecordPerRow() {
        System.runAs(DataImportTestUser.get()) {
            register(simpleTemplate());

            DataImportWalker.Outcome outcome = walkerFor(TEMPLATE)
                .walk(DataImport.parse('Name,Number,Staff\nAcme,A-1,50\nBeta,B-2,10'), 1);

            Assert.areEqual(2, outcome.rows.size(), 'the heading row is not data');
            Assert.areEqual(0, outcome.errors.size());
            Assert.areEqual('Acme', outcome.rows[0].record.get('Name'));
            Assert.areEqual(50, outcome.rows[0].record.get('NumberOfEmployees'));
            Assert.areEqual(2, outcome.rows[0].rowNumber, 'row numbers are the file\'s own');
        }
    }

    /**
     * A chunk from the middle of a file carries no headings, and must still know which
     * rows are data. This is what lets Batch Apex process chunks in any order.
     */
    @isTest
    static void walk_chunkStartingMidFile_numbersRowsFromTheOffset() {
        System.runAs(DataImportTestUser.get()) {
            register(simpleTemplate());

            DataImportWalker.Outcome outcome = walkerFor(TEMPLATE)
                .walk(DataImport.parse('Gamma,C-3,5\nDelta,D-4,7'), 900);

            Assert.areEqual(2, outcome.rows.size());
            Assert.areEqual(900, outcome.rows[0].rowNumber);
            Assert.areEqual('Delta', outcome.rows[1].record.get('Name'));
        }
    }

    @isTest
    static void walk_unreadableCell_failsThatRowOnly() {
        System.runAs(DataImportTestUser.get()) {
            register(simpleTemplate());

            DataImportWalker.Outcome outcome = walkerFor(TEMPLATE)
                .walk(DataImport.parse('Name,Number,Staff\nAcme,A-1,not a number'), 1);

            Assert.areEqual(1, outcome.errors.size());
            Assert.isTrue(outcome.errors[0].contains('Row 2'), outcome.errors[0]);
            Assert.isTrue(outcome.errors[0].contains('column C'), outcome.errors[0]);
            Assert.isTrue(outcome.rows[0].failed, 'the row must not be written');
            Assert.areEqual(0, outcome.usable().size());
        }
    }

    /** A blank line inside a table is skipped, and the rows after it keep their own numbers. */
    @isTest
    static void walk_blankRowInsideASection_isSkipped() {
        System.runAs(DataImportTestUser.get()) {
            register(simpleTemplate());

            DataImportWalker.Outcome outcome = walkerFor(TEMPLATE)
                .walk(DataImport.parse('Name,Number,Staff\nAcme,A-1,50\n,,\nBeta,B-2,10'), 1);

            Assert.areEqual(2, outcome.rows.size(), 'the blank row is not a record');
            Assert.areEqual(0, outcome.errors.size());
            Assert.areEqual(2, outcome.rows[0].rowNumber);
            Assert.areEqual(4, outcome.rows[1].rowNumber);
            Assert.areEqual('Beta', outcome.rows[1].record.get('Name'));
        }
    }

    /** A column key that is not a spreadsheet letter maps nothing, rather than failing the row. */
    @isTest
    static void walk_columnKeyThatIsNotALetter_isIgnored() {
        System.runAs(DataImportTestUser.get()) {
            register(simpleTemplate().replace('"B":', '"2":'));

            DataImportWalker.Outcome outcome = walkerFor(TEMPLATE)
                .walk(DataImport.parse('Acme,A-1,50'), 2);

            Assert.areEqual(0, outcome.errors.size());
            Assert.areEqual('Acme', outcome.rows[0].record.get('Name'));
            Assert.isNull(outcome.rows[0].record.get('AccountNumber'));
            Assert.areEqual(50, outcome.rows[0].record.get('NumberOfEmployees'));
        }
    }

    /**
     * Defaults are a literal, a `$binding` resolved from the job, or blank - and a blank
     * one writes nothing rather than an empty string.
     */
    @isTest
    static void walk_sectionDefaults_stampLiteralsAndBindings() {
        System.runAs(DataImportTestUser.get()) {
            Map<String, Object> definition = (Map<String, Object>) JSON.deserializeUntyped(simpleTemplate());
            ((Map<String, Object>) ((List<Object>) definition.get('sections'))[0]).put(
                'defaults',
                new Map<String, String>{
                    'Description' => 'Imported',
                    'Site' => '$site',
                    'Industry' => ''
                }
            );
            register(JSON.serialize(definition));
            DataImportWalker walker = new DataImportWalker(
                DataImportSpec.load(TEMPLATE),
                null,
                new Map<String, Object>{ 'site' => 'Head Office' }
            );

            DataImportWalker.Outcome outcome = walker.walk(DataImport.parse('Acme,A-1,50'), 2);

            SObject record = outcome.rows[0].record;
            Assert.areEqual('Imported', record.get('Description'));
            Assert.areEqual('Head Office', record.get('Site'));
            Assert.isNull(record.get('Industry'));
        }
    }

    // ---------------- sections ----------------

    /** Two tables in one file, told apart only by the ranges the uploader resolved. */
    @isTest
    static void walk_severalSectionRanges_routesRowsToTheirOwnSection() {
        System.runAs(DataImportTestUser.get()) {
            register(
                JSON.serialize(
                    new Map<String, Object>{
                        'sections' => new List<Object>{
                            new Map<String, Object>{
                                'type' => 'rows',
                                'sectionName' => 'first',
                                'target' => 'Account',
                                'firstDataRow' => 2,
                                'columns' => new Map<String, String>{ 'A' => 'Name' }
                            },
                            new Map<String, Object>{
                                'type' => 'rows',
                                'sectionName' => 'second',
                                'target' => 'Account',
                                'firstDataRow' => 6,
                                'columns' => new Map<String, String>{ 'A' => 'AccountNumber' }
                            }
                        }
                    }
                )
            );

            DataImportWalker.Outcome outcome = walkerFor(
                    TEMPLATE,
                    '[{"sectionName":"first","firstRow":2,"lastRow":3},' +
                    '{"sectionName":"second","firstRow":6,"lastRow":null}]'
                )
                .walk(DataImport.parse('h\nAcme\nBeta\n\nheading\nX-9'), 1);

            Assert.areEqual(3, outcome.rows.size(), 'the gap row belongs to no section');
            Assert.areEqual('first', outcome.rows[0].section);
            Assert.areEqual('second', outcome.rows[2].section);
            Assert.areEqual('X-9', outcome.rows[2].record.get('AccountNumber'));
        }
    }

    /**
     * The uploader sends sectionName:'' for a template with one table, because it has
     * no name to send. Matching that against a null name found nothing and skipped
     * every row - the file imported as "0 rows read" with no error anywhere.
     */
    @isTest
    static void walk_unnamedSectionRange_stillClaimsItsRows() {
        System.runAs(DataImportTestUser.get()) {
            register(simpleTemplate());

            DataImportWalker.Outcome outcome = walkerFor(
                    TEMPLATE,
                    '[{"sectionName":"","firstRow":2,"lastRow":null}]'
                )
                .walk(DataImport.parse('Name,Number,Staff\nAcme,A-1,50\nBeta,B-2,10'), 1);

            Assert.areEqual(2, outcome.rows.size(), 'an unnamed section must still claim its rows');
            Assert.areEqual('Acme', outcome.rows[0].record.get('Name'));
        }
    }

    // ---------------- groups ----------------

    @isTest
    static void groups_yesColumns_foldIntoOneField() {
        System.runAs(DataImportTestUser.get()) {
            register(groupedTemplate('Name'));
            Id jobId = newJob(TEMPLATE);
            DataImportJob.stage(jobId, 0, 1, 'Both,Yes,Y\nFirst,x,No\nNeither,No,\n');

            Test.startTest();
            DataImportJob.run(jobId, 1, null);
            Test.stopTest();

            Map<String, Account> byName = new Map<String, Account>();
            for (Account acct : [SELECT Name, Description FROM Account]) {
                byName.put(acct.Name, acct);
            }
            // Order is not asserted: the options come out of a Map, whose iteration order Apex
            // does not define, so the joined string is legitimately 'Alpha;Beta' or 'Beta;Alpha'.
            // Asserting the literal made this test fail on roughly half of its runs.
            Assert.areEqual(
                new Set<String>{ 'Alpha', 'Beta' },
                new Set<String>(byName.get('Both').Description.split(';')),
                'every Yes contributes its value, joined'
            );
            Assert.areEqual(
                'Alpha',
                byName.get('First').Description,
                'a tick is a Yes; the No column contributes nothing'
            );
            Assert.isNull(
                byName.get('Neither').Description,
                'nothing selected leaves the field alone rather than writing an empty string'
            );
        }
    }

    /**
     * A row can carry nothing but a Yes in a group column - on the SF-428C sheet,
     * "request Federal Agency disposition instructions" and no other answer. Blank-row
     * detection has to count those columns, or the row is skipped silently and
     * `endsAt: blankRow` ends the table early.
     */
    @isTest
    static void groups_rowWhoseOnlyAnswerIsAGroupColumn_isNotBlank() {
        System.runAs(DataImportTestUser.get()) {
            // The group feeds Name, so the row's only content is its Yes.
            register(groupedTemplate('AccountNumber').replace('"Description"', '"Name"'));
            Id jobId = newJob(TEMPLATE);
            DataImportJob.stage(jobId, 0, 1, ',Yes,No\n');

            Test.startTest();
            DataImportJob.run(jobId, 1, null);
            Test.stopTest();

            Assert.areEqual(
                1,
                reload(jobId).Records_Committed__c,
                'the row was read rather than judged blank'
            );
            Assert.areEqual(
                1,
                [SELECT COUNT() FROM Account WHERE Name = 'Alpha'],
                'and its Yes reached the field'
            );
        }
    }

    /**
     * A group option that is not one of the field's values is a stale template, not a
     * bad file - but without this the recipient is the one who sees it, as a platform
     * error over the whole upload.
     */
    @isTest
    static void groups_optionTheFieldDoesNotAccept_failsTheRow() {
        System.runAs(DataImportTestUser.get()) {
            register(
                groupedTemplate('Name')
                    .replace('"Description"', '"Industry"')
                    .replace('"Alpha"', '"Not An Industry"')
            );
            Id jobId = newJob(TEMPLATE);
            DataImportJob.stage(jobId, 0, 1, 'Acme,Yes,No\n');

            Test.startTest();
            DataImportJob.run(jobId, 1, null);
            Test.stopTest();

            Data_Import_Job__c job = reload(jobId);
            Assert.areEqual(1, job.Rows_Failed__c, 'the row failed rather than the job');
            Assert.isTrue(
                job.Errors__c.contains('column B') && job.Errors__c.contains('Industry'),
                'the message names the column and the field to correct: ' + job.Errors__c
            );
            Assert.areEqual(0, [SELECT COUNT() FROM Account], 'and nothing was written');
        }
    }

    /** A group with no options selects nothing, and leaves the groups beside it working. */
    @isTest
    static void groups_groupWithNoOptions_isSkipped() {
        System.runAs(DataImportTestUser.get()) {
            Map<String, Object> definition = (Map<String, Object>) JSON.deserializeUntyped(
                groupedTemplate('Name')
            );
            Map<String, Object> section = (Map<String, Object>) ((List<Object>) definition.get('sections'))[0];
            ((List<Object>) section.get('groups')).add(new Map<String, Object>{ 'field' => 'Site' });
            register(JSON.serialize(definition));

            DataImportWalker.Outcome outcome = walkerFor(TEMPLATE)
                .walk(DataImport.parse('Acme,Yes,No'), 1);

            Assert.areEqual(0, outcome.errors.size());
            Assert.areEqual('Alpha', outcome.rows[0].record.get('Description'));
            Assert.isNull(outcome.rows[0].record.get('Site'));
        }
    }

    // ---------------- encode ----------------

    /** A row is handed back as CSV so a failed one can go into a file the user re-uploads. */
    @isTest
    static void encode_cellsNeedingQuotes_producesCsv() {
        System.runAs(DataImportTestUser.get()) {
            Assert.areEqual(
                'a,"one, two","say ""hi"""',
                DataImportWalker.encode(new List<String>{ 'a', 'one, two', 'say "hi"' })
            );
        }
    }

    @isTest
    static void encode_nullCell_writesAnEmptyField() {
        System.runAs(DataImportTestUser.get()) {
            Assert.areEqual(
                'a,,b',
                DataImportWalker.encode(new List<String>{ 'a', null, 'b' })
            );
        }
    }
}
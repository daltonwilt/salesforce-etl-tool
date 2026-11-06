/**********************************************************************************
* Name         : DataImportJobTest
* Author       : Dalton Wilt
* Desc         : Tests for DataImportJob - the @AuraEnabled entry points the
*                uploader calls (start, stage, run, status, getTemplates) and the
*                prepare pass that runs before a single row is read.
*
*                Prepare is where a job is stopped rather than half-imported: a file
*                whose columns have shifted, a template whose parent binding was
*                never supplied, and the cell values at the top of a file that have
*                to reach chunks which never see the top of the file. Each of those
*                is cheaper to catch here than to undo afterwards.
*
*                Templates come through DataImportSpec.jsonOverride - Custom
*                Metadata records cannot be inserted from Apex.
* Created On   : 2026-08-20
*
* Class under test : DataImportJob
*
* Modification Log:
* ----------------------------------------------------------------------
* Developer        Date          Description
* ----------------------------------------------------------------------
* Dalton Wilt      2026-08-20    Split out of DataImportFrameworkTest.
* Dalton Wilt      2026-11-06    Run as DataImportTestUser, with Data_Import_User.
* Dalton Wilt      2026-11-06    Cover the remaining DataImportJob paths.
**********************************************************************************/

@isTest
private class DataImportJobTest {

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

    private static void register(String json) {
        DataImportSpec.jsonOverride = new Map<String, String>{ TEMPLATE => json };
        DataImportSpec.clearCache();
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
            SELECT Status__c, Rows_Read__c, Header_Rows__c
            FROM Data_Import_Job__c
            WHERE Id = :jobId
            LIMIT 1
        ];
    }

    // ---------------- prepare ----------------

    /** Cells at the top of the file must reach a row in a chunk that never sees the top of the file. */
    @isTest
    static void prepare_cellSection_reachesTheRowsAsABinding() {
        System.runAs(DataImportTestUser.get()) {
            register(
                JSON.serialize(
                    new Map<String, Object>{
                        'sections' => new List<Object>{
                            new Map<String, Object>{
                                'type' => 'cells',
                                'applyTo' => 'defaults',
                                'cells' => new Map<String, String>{ 'B2' => 'Site' }
                            },
                            new Map<String, Object>{
                                'type' => 'rows',
                                'target' => 'Account',
                                'firstDataRow' => 5,
                                'columns' => new Map<String, String>{ 'A' => 'Name' },
                                'defaults' => new Map<String, String>{ 'Site' => '$Site' }
                            }
                        }
                    }
                )
            );

            Id jobId = newJob(TEMPLATE);
            DataImportJob.stage(jobId, 0, 1, 'title\nPeriod,Q3 2026\n\nName\nAcme');

            Test.startTest();
            DataImportJob.run(jobId, 1, null);
            Test.stopTest();

            Assert.areEqual(
                'Q3 2026',
                [SELECT Site FROM Account WHERE Name = 'Acme' LIMIT 1].Site,
                'the cell value reached the row'
            );
        }
    }

    /** A shifted column would import every row successfully into the wrong fields. */
    @isTest
    static void prepare_columnsHaveMoved_failsTheJob() {
        System.runAs(DataImportTestUser.get()) {
            Map<String, Object> definition = (Map<String, Object>) JSON.deserializeUntyped(simpleTemplate());
            List<Object> sections = (List<Object>) definition.get('sections');
            ((Map<String, Object>) sections[0])
                .put('expectHeader', new Map<String, String>{ 'A' => 'Name' });
            register(JSON.serialize(definition));

            Id jobId = newJob(TEMPLATE);
            DataImportJob.stage(jobId, 0, 1, 'Region,Name,Number\nEast,Acme,A-1');

            Test.startTest();
            try {
                DataImportJob.run(jobId, 1, null);
                Assert.fail('Expected the header check to stop this.');
            } catch (Exception e) {
                Assert.isTrue(e.getMessage().contains('Column A'), e.getMessage());
            }
            Test.stopTest();

            Assert.areEqual('Failed', reload(jobId).Status__c);
            Assert.areEqual(0, [SELECT COUNT() FROM Account]);
        }
    }

    @isTest
    static void prepare_headerBlock_isKeptForTheRejectFile() {
        System.runAs(DataImportTestUser.get()) {
            register(simpleTemplate());
            Id jobId = newJob(TEMPLATE);
            DataImportJob.stage(jobId, 0, 1, 'Name,Number,Staff\nAcme,A-1,5');

            Test.startTest();
            DataImportJob.run(jobId, 1, null);
            Test.stopTest();

            Assert.areEqual('Name,Number,Staff', reload(jobId).Header_Rows__c);
        }
    }

    /**
     * A template built for a host component, run from the standalone importer, would
     * otherwise create every record with an empty parent lookup - orphans nothing can
     * reach.
     */
    @isTest
    static void prepare_parentBindingNotSupplied_failsTheJob() {
        System.runAs(DataImportTestUser.get()) {
            register(
                simpleTemplate().replace('"columns"', '"defaults":{"ParentId":"$accountId"},"columns"')
            );
            Id jobId = newJob(TEMPLATE); // bindingsJson is '{}'
            DataImportJob.stage(jobId, 0, 1, 'Name,Number,Staff\nAcme,A-1,50');

            Test.startTest();
            try {
                DataImportJob.run(jobId, 1, null);
                Assert.fail('Expected the missing binding to stop this.');
            } catch (Exception e) {
                Assert.isTrue(e.getMessage().contains('accountId'), e.getMessage());
            }
            Test.stopTest();

            Assert.areEqual('Failed', reload(jobId).Status__c);
            Assert.areEqual(0, [SELECT COUNT() FROM Account], 'nothing was created');
        }
    }

    /** A header row past the end of the file reads as blank, so the heading check still stops it. */
    @isTest
    static void prepare_headerRowPastEndOfFile_failsTheJob() {
        System.runAs(DataImportTestUser.get()) {
            Map<String, Object> definition = (Map<String, Object>) JSON.deserializeUntyped(simpleTemplate());
            Map<String, Object> section = (Map<String, Object>) ((List<Object>) definition.get('sections'))[0];
            section.put('headerRow', 3);
            section.put('firstDataRow', 4);
            section.put('expectHeader', new Map<String, String>{ 'A' => 'Name' });
            register(JSON.serialize(definition));

            Id jobId = newJob(TEMPLATE);
            DataImportJob.stage(jobId, 0, 1, 'Acme,A-1,5');

            Test.startTest();
            try {
                DataImportJob.run(jobId, 1, null);
                Assert.fail('Expected the header check to stop this.');
            } catch (Exception e) {
                Assert.isTrue(e.getMessage().contains('this file has ""'), e.getMessage());
            }
            Test.stopTest();

            Assert.areEqual('Failed', reload(jobId).Status__c);
            Assert.areEqual(0, [SELECT COUNT() FROM Account]);
        }
    }

    /**
     * Cells that cannot be read - a section with no cells, an address below the last
     * row, an address that is not an address - are skipped rather than bound to blank.
     */
    @isTest
    static void resolveCells_unreadableAddresses_areSkipped() {
        System.runAs(DataImportTestUser.get()) {
            register(
                JSON.serialize(
                    new Map<String, Object>{
                        'sections' => new List<Object>{
                            new Map<String, Object>{
                                'type' => 'cells',
                                'applyTo' => 'defaults'
                            },
                            new Map<String, Object>{
                                'type' => 'cells',
                                'applyTo' => 'defaults',
                                'cells' => new Map<String, String>{
                                    'B1' => 'period',
                                    'B9' => 'pastTheEnd',
                                    'Total' => 'notAnAddress'
                                }
                            },
                            new Map<String, Object>{
                                'type' => 'rows',
                                'target' => 'Account',
                                'firstDataRow' => 3,
                                'columns' => new Map<String, String>{ 'A' => 'Name' }
                            }
                        }
                    }
                )
            );

            Map<String, Object> bindings = DataImportJob.resolveCells(
                DataImportSpec.load(TEMPLATE),
                DataImport.parse('Period,Q3 2026\nName\nAcme'),
                null
            );

            Assert.areEqual(1, bindings.size(), String.valueOf(bindings));
            Assert.areEqual('Q3 2026', bindings.get('period'));
            Assert.isFalse(bindings.containsKey('pastTheEnd'));
            Assert.isFalse(bindings.containsKey('notAnAddress'));
        }
    }

    /** The section map is only known once the file is read, so the one given to run() is what the batch uses. */
    @isTest
    static void run_sectionMapSupplied_limitsTheRowsImported() {
        System.runAs(DataImportTestUser.get()) {
            register(simpleTemplate());
            Id jobId = newJob(TEMPLATE);
            DataImportJob.stage(jobId, 0, 1, 'Name,Number,Staff\nAcme,A-1,5\nBeta,B-2,6');
            String sectionMap = '[{"sectionName":"","firstRow":2,"lastRow":2}]';

            Test.startTest();
            DataImportJob.run(jobId, 1, sectionMap);
            Test.stopTest();

            Assert.areEqual(
                sectionMap,
                [SELECT Section_Map__c FROM Data_Import_Job__c WHERE Id = :jobId].Section_Map__c
            );
            List<Account> imported = [SELECT Name FROM Account];
            Assert.areEqual(1, imported.size(), 'row 3 is outside the mapped range');
            Assert.areEqual('Acme', imported[0].Name);
        }
    }

    // ---------------- permissions ----------------

    @isTest
    static void assertWritable_objectNotCreateable_refusesTheJob() {
        System.runAs(DataImportTestUser.get()) {
            register(simpleTemplate().replace('"Account"', '"AsyncApexJob"'));

            try {
                DataImportJob.assertWritable(DataImportSpec.load(TEMPLATE));
                Assert.fail('Expected the permission check to stop this.');
            } catch (DataImport.DataImportException e) {
                Assert.isTrue(
                    e.getMessage().contains('create ' + Schema.SObjectType.AsyncApexJob.getLabel()),
                    e.getMessage()
                );
            }
        }
    }

    /** A broadcast only updates children, so it is edit access on the child that matters. */
    @isTest
    static void assertWritable_broadcastToObjectNotUpdateable_refusesTheJob() {
        System.runAs(DataImportTestUser.get()) {
            Map<String, Object> definition = (Map<String, Object>) JSON.deserializeUntyped(simpleTemplate());
            ((Map<String, Object>) ((List<Object>) definition.get('sections'))[0]).put(
                'applyToChildren',
                new Map<String, String>{
                    'childObject' => 'AsyncApexJob',
                    'parentField' => 'ParentJobId',
                    'parentId' => '$jobId'
                }
            );
            register(JSON.serialize(definition));

            try {
                DataImportJob.assertWritable(DataImportSpec.load(TEMPLATE));
                Assert.fail('Expected the permission check to stop this.');
            } catch (DataImport.DataImportException e) {
                Assert.isTrue(
                    e.getMessage().contains('edit ' + Schema.SObjectType.AsyncApexJob.getLabel()),
                    e.getMessage()
                );
            }
        }
    }

    /** Every unwritable field is named in the one message, so they can all be fixed at once. */
    @isTest
    static void assertWritable_unknownAndReadOnlyFields_namesEachOne() {
        System.runAs(DataImportTestUser.get()) {
            register(
                simpleTemplate()
                    .replace('"AccountNumber"', '"No_Such_Field__c"')
                    .replace('"NumberOfEmployees"', '"IsDeleted"')
            );
            String account = Schema.SObjectType.Account.getLabel();

            try {
                DataImportJob.assertWritable(DataImportSpec.load(TEMPLATE));
                Assert.fail('Expected the permission check to stop this.');
            } catch (DataImport.DataImportException e) {
                String message = e.getMessage();
                Assert.isTrue(message.contains('No_Such_Field__c (no such field on ' + account + ')'), message);
                Assert.isTrue(
                    message.contains(account + '.' + Schema.SObjectType.Account.fields.IsDeleted.getLabel()),
                    message
                );
                Assert.isFalse(
                    message.contains(account + '.' + Schema.SObjectType.Account.fields.Name.getLabel()),
                    'a writable field is not reported'
                );
            }
        }
    }

    // ---------------- guards ----------------

    @isTest
    static void run_jobWithNoFile_fails() {
        System.runAs(DataImportTestUser.get()) {
            register(simpleTemplate());
            Id jobId = newJob(TEMPLATE);

            Test.startTest();
            try {
                DataImportJob.run(jobId, 0, null);
                Assert.fail('Expected a failure.');
            } catch (Exception e) {
                Assert.isTrue(e.getMessage().contains('no file'), e.getMessage());
            }
            Test.stopTest();

            Assert.areEqual('Failed', reload(jobId).Status__c);
        }
    }

    @isTest
    static void start_templateThatDoesNotExist_throws() {
        System.runAs(DataImportTestUser.get()) {
            DataImportSpec.jsonOverride = new Map<String, String>();
            DataImportSpec.clearCache();

            try {
                newJob('NoSuchTemplate');
                Assert.fail('Expected a failure.');
            } catch (Exception e) {
                Assert.isNotNull(e.getMessage());
            }
        }
    }

    /** A failed stage must reach the uploader as the real DML error, not "Script-thrown exception". */
    @isTest
    static void stage_chunkWithNoJob_throwsAReadableError() {
        System.runAs(DataImportTestUser.get()) {
            try {
                DataImportJob.stage(null, 0, 1, 'Name\nAcme');
                Assert.fail('Expected a failure.');
            } catch (Exception e) {
                Assert.isInstanceOfType(e, AuraHandledException.class);
                Assert.isTrue(e.getMessage().contains('Insert failed'), e.getMessage());
            }
            Assert.areEqual(0, [SELECT COUNT() FROM Data_Import_Chunk__c]);
        }
    }

    /**
     * When the job cannot be marked failed either, the caller still gets the original
     * error rather than the one from the bookkeeping.
     */
    @isTest
    static void run_jobThatDoesNotExist_reportsTheOriginalError() {
        System.runAs(DataImportTestUser.get()) {
            Id missing = Id.valueOf(
                Data_Import_Job__c.SObjectType.getDescribe().getKeyPrefix() + '000000000000'
            );

            try {
                DataImportJob.run(missing, 1, null);
                Assert.fail('Expected a failure.');
            } catch (Exception e) {
                Assert.isInstanceOfType(e, AuraHandledException.class);
                Assert.isTrue(e.getMessage().contains('List has no rows'), e.getMessage());
            }
        }
    }

    // ---------------- status and templates ----------------

    @isTest
    static void status_afterARun_reportsProgress() {
        System.runAs(DataImportTestUser.get()) {
            register(simpleTemplate());
            Id jobId = newJob(TEMPLATE);
            DataImportJob.stage(jobId, 0, 1, 'Name,Number,Staff\nAcme,A-1,5');

            Test.startTest();
            DataImportJob.run(jobId, 1, null);
            Test.stopTest();

            Data_Import_Job__c job = DataImportJob.status(jobId);
            Assert.isNotNull(job);
            Assert.areEqual(1, job.Rows_Read__c);
        }
    }

    @isTest
    static void getTemplates_noMetadataDeployed_stillReturnsAList() {
        System.runAs(DataImportTestUser.get()) {
            Test.startTest();
            List<DataImportJob.TemplateInfo> found = DataImportJob.getTemplates();
            Test.stopTest();

            Assert.isNotNull(found, 'returns a list even with no metadata deployed');
        }
    }

    @isTest
    static void getTemplate_partialSuccessTemplate_describesItForTheUploader() {
        System.runAs(DataImportTestUser.get()) {
            Map<String, Object> definition = (Map<String, Object>) JSON.deserializeUntyped(simpleTemplate());
            definition.put('mode', 'Partial Success');
            definition.put('abortAfterErrors', 25);
            register(JSON.serialize(definition));

            Test.startTest();
            DataImportJob.TemplateInfo info = DataImportJob.getTemplate(TEMPLATE);
            Test.stopTest();

            Assert.areEqual(TEMPLATE, info.name);
            Assert.areEqual('Test Accounts', info.label);
            Assert.isFalse(info.allOrNothing);
            Assert.areEqual(25, info.abortAfterErrors);
            Map<String, Object> sent = (Map<String, Object>) JSON.deserializeUntyped(info.definition);
            Assert.areEqual(1, ((List<Object>) sent.get('sections')).size(), 'the definition carries its sections');
        }
    }

    @isTest
    static void getTemplate_noLabelOrMode_fallsBackToDefaults() {
        System.runAs(DataImportTestUser.get()) {
            Map<String, Object> definition = (Map<String, Object>) JSON.deserializeUntyped(simpleTemplate());
            definition.remove('label');
            register(JSON.serialize(definition));

            Test.startTest();
            DataImportJob.TemplateInfo info = DataImportJob.getTemplate(TEMPLATE);
            Test.stopTest();

            Assert.areEqual(TEMPLATE, info.label, 'the picker shows the name when there is no label');
            Assert.isTrue(info.allOrNothing, 'all or nothing unless the template opts out');
            Assert.areEqual(DataImportSpec.DEFAULT_ABORT_AFTER, info.abortAfterErrors);
        }
    }
}
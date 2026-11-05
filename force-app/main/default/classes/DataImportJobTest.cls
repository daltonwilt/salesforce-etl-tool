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

    /** A shifted column would import every row successfully into the wrong fields. */
    @isTest
    static void prepare_columnsHaveMoved_failsTheJob() {
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

    @isTest
    static void prepare_headerBlock_isKeptForTheRejectFile() {
        register(simpleTemplate());
        Id jobId = newJob(TEMPLATE);
        DataImportJob.stage(jobId, 0, 1, 'Name,Number,Staff\nAcme,A-1,5');

        Test.startTest();
        DataImportJob.run(jobId, 1, null);
        Test.stopTest();

        Assert.areEqual('Name,Number,Staff', reload(jobId).Header_Rows__c);
    }

    /**
     * A template built for a host component, run from the standalone importer, would
     * otherwise create every record with an empty parent lookup - orphans nothing can
     * reach.
     */
    @isTest
    static void prepare_parentBindingNotSupplied_failsTheJob() {
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

    // ---------------- guards ----------------

    @isTest
    static void run_jobWithNoFile_fails() {
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

    @isTest
    static void start_templateThatDoesNotExist_throws() {
        DataImportSpec.jsonOverride = new Map<String, String>();
        DataImportSpec.clearCache();

        try {
            newJob('NoSuchTemplate');
            Assert.fail('Expected a failure.');
        } catch (Exception e) {
            Assert.isNotNull(e.getMessage());
        }
    }

    // ---------------- status and templates ----------------

    @isTest
    static void status_afterARun_reportsProgress() {
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

    @isTest
    static void getTemplates_noMetadataDeployed_stillReturnsAList() {
        Test.startTest();
        List<DataImportJob.TemplateInfo> found = DataImportJob.getTemplates();
        Test.stopTest();

        Assert.isNotNull(found, 'returns a list even with no metadata deployed');
    }
}
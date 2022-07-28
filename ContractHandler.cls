/******************************************************//**

@copyright  (c)2022, Real Property Management Commonwealth
**********************************************************/

public inherited sharing class ContractHandler extends TriggerContext.Handler
{
    /**************************************************//**
    @method     handleBeforeInsert
    @brief      Perform before insert trigger logic
    ******************************************************/
    public override void handleBeforeInsert()
    {
        runHandlerProcesses
        (   new List<TriggerContext.HandlerProcess>
            { new SetContractUnit()
            }
        );
    }

    /**************************************************//**
    @method     handleBeforeUpdate
    @brief      Perform before insert trigger logic
    ******************************************************/
    public override void handleBeforeUpdate()
    {
        runHandlerProcesses
        (   new List<TriggerContext.HandlerProcess>
            {   new SetContractStatus()
            }
        );
    }

    /**************************************************//**
    @method     handleAfterInsert
    @brief      Perform before insert trigger logic
    ******************************************************/
    public override void handleAfterInsert()
    {
        runHandlerProcesses
        (   new List<TriggerContext.HandlerProcess>
            {   new SetContractStatus()
            ,   new SetPropertyLookups()
            }
        );
    }

    /**************************************************//**
    @method     handleAfterUpdate
    @brief      Perform before insert trigger logic
    ******************************************************/
    public override void handleAfterUpdate()
    {
        runHandlerProcesses
        (   new List<TriggerContext.HandlerProcess>
            {   new SetPropertyLookups()
            ,   new UpdateParentRollups()
            ,   new TerminatedContractOppurtunityCloser()    
            }
        );
    }

    /**************************************************//**
    @class      UpdateParentRollups
    ******************************************************/

    public class UpdateParentRollups extends TriggerContext.HandlerProcess
    {
        /**************************************************//**
        @method     process
        @brief      call update on appropriate parent accounts to adjust rollups
        ******************************************************/
        public override void process()
        {
            Map<Id, Account> OwnersForUpdate = new Map<Id, Account>();
            for (Contract ctrt : (List<Contract>)context.records)
            {
                Contract related = (Contract) context.relatedData.get( ctrt.Id );
                if (ctrt.RecordType.DeveloperName != MANAGEMENT_AGREEMENT_RTNAME) continue;
                OwnersForUpdate.put(ctrt.AccountId, new account(Id = ctrt.AccountId));
            }
            update OwnersForUpdate.values();
        }
    }

    /**************************************************//**
    @class      SetContractUnit
    ******************************************************/

    public class SetContractUnit extends TriggerContext.HandlerProcess
    {
        /**************************************************//**
        @method     process
        @brief      set the Contract lookup to the Rental Unit for Leases(rental agreements)
        ******************************************************/
        public override void process()
        {
            Id rtIdForRentalUnits = Utilities.recordTypes.get('Contract').get(RENTAL_AGREEMENT_RTNAME) == null ? null : Utilities.recordTypes.get('Contract').get(RENTAL_AGREEMENT_RTNAME).Id;
            Map<String, List<Contract>> contractsByRentalUnitExtId = new Map<String, List<Contract>>();
            for (Contract ctrt : (List<Contract>)context.records)
            {
                if (ctrt.AccountId != null || ctrt.UnitExternalId__c == null || ctrt.RecordTypeId != rtIdForRentalUnits) continue;
                String key = RENTAL_UNIT_RTNAME + '-' + ctrt.UnitExternalId__c;
                List<Contract> cList = contractsByRentalUnitExtId.get(key) == null ? new List<Contract>() : contractsByRentalUnitExtId.get(key);
                cList.add(ctrt);
                contractsByRentalUnitExtId.put(key, cList);                
            }

            for (Account acct : [
                    SELECT Id, UniqueExternalId__c 
                    FROM Account 
                    WHERE UniqueExternalId__c IN :contractsByRentalUnitExtId.keyset()]) 
            {
                for (Contract ctrt : contractsByRentalUnitExtId.get(acct.UniqueExternalId__c)) ctrt.AccountId = acct.Id; 
            }
        }        
    }

    /**************************************************//**
    @class      SetContractStatus
    ******************************************************/

    public class SetContractStatus extends TriggerContext.HandlerProcess
    {
        /**************************************************//**
        @method     process
        @brief      set the status on Contracts
        ******************************************************/
        public override void process()
        {
            Set<Id> recordsToActivate = new Set<Id>();
            for (Contract ctrt : (List<Contract>)context.records) {
                if (ctrt.Status != 'Active' && ctrt.StatusCode != 'Activated') recordsToActivate.add(ctrt.Id);
            }
            if ( recordsToActivate.isEmpty() ) return;
            setAsynchronousProcessType( 'ContractHandler.SetContractStatus' );
            putAsynchronousParameter( 'recordsToActivate', recordsToActivate );
        }

        /**************************************************//**
        @method     asynchronousProcess
        @brief      update the related contracts in a different transaction
        ******************************************************/
        public override void asynchronousProcess()
        {
            Set<Id> recordsToActivate = (Set<Id>) getAsynchronousParameter( 'recordsToActivate', Set<Id>.class );
            List<Contract> contractsToUpdate = new List<Contract>();
            for ( Id recordId : recordsToActivate )
            {
                contractsToUpdate.add( new Contract( Id = recordId, Status = 'Active' ) );
            }
            update contractsToUpdate;
        }
    }

    /**************************************************//**
    @class      SetPropertyLookups
    ******************************************************/

    private class SetPropertyLookups extends TriggerContext.HandlerProcess
    {
        /**************************************************//**
        @construtor
        @brief      Sets related data selections
        ******************************************************/
        private SetPropertyLookups()
        {
            context.addRelatedDataSelections
            (   new List<String>
                {   'Account.RecordType.DeveloperName'
                ,   'Account.Id'
                ,   'Account.LeaseContract__c'
                }
            );
        }
    
        /**************************************************//**
        @method     process
        @brief      Sets property lookups to agreements
        ******************************************************/
        public override void process()
        {
            List<Account> propertiesForUpdate = new List<Account>();
            for (Contract ctrt : (List<Contract>)context.records)
            {
                if ( !context.hasBecome( ctrt, 'Status', 'Active' ) ) continue;
                Contract related = (Contract) context.relatedData.get( ctrt.Id );
                Account account = related.Account;
                if ( account.RecordType.DeveloperName != RENTAL_UNIT_RTNAME ) continue;

                account.LeaseContract__c = ctrt.Id;
                propertiesForUpdate.add(account);
            }
            update propertiesForUpdate;
        }
    }

    /**************************************************//**
    @class      TerminatedContractOppurtunityCloser
    ******************************************************/

    private class TerminatedContractOppurtunityCloser extends TriggerContext.HandlerProcess
    {
        /**************************************************//**
        @method     process
        @brief      Sets property lookups to agreements
        ******************************************************/
        public override void process()
        {
            Set<Id> terminatedContracts = new Set<Id>();
            for (Contract ctrt : (List<Contract>)context.records) 
            {
                if (context.hasBecome(ctrt, 'Status', 'Terminated by RPM') || context.hasBecome(ctrt, 'Status', 'Terminted by Owner'))
                {
                    terminatedContracts.add(ctrt.Id);
                }
            }
            List<Opportunity> opportunitiesToClose = [SELECT Id, StageName FROM Opportunity WHERE AccountId IN (SELECT Id FROM Account WHERE ManagementContract__c IN :terminatedContracts)];
            
            for( Opportunity opp : opportunitiesToClose )
            {
                opp.StageName = 'Closed Lost';
            }
            update opportunitiesToClose;
        }
    }

    /**************************************************//**
    @constants  
    ******************************************************/
    static private final String RENTAL_UNIT_RTNAME = 'Rental_Unit';
    static private final String RENTAL_AGREEMENT_RTNAME = 'Rental_Agreement';
    static private final String MANAGEMENT_AGREEMENT_RTNAME = 'Management';
}
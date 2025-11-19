module simpleSales.core

entity Lead {
    id UUID @id @default(uuid()),
    firstName String,
    lastName String,
    email Email,
    phone String @optional,
    company String @optional,
    jobTitle String @optional,
    leadStatus @enum("New", "Contacted", "Qualified", "Unqualified") @default("new"),
    lifecycleStage @enum("lead", "marketing_qualified_lead", "sales_qualified_lead", "opportunity", "customer") @default("lead"),
    source String @optional,
    notes String @optional,
    hubspotId String @optional,
    score Int @default(0),
    createdAt DateTime @default(now()),
    lastContactedAt DateTime @optional,
    @after {create syncLeadToHubSpot @async}
}

entity Deal {
    id UUID @id @default(uuid()),
    dealName String,
    dealStage @enum("prospecting", "qualification", "proposal", "negotiation", "closed_won", "closed_lost") @default("prospecting"),
    amount Decimal @optional,
    closeDate DateTime @optional,
    priority @enum("low", "medium", "high") @default("medium"),
    hubspotId String @optional,
    leadId UUID @optional,
    createdAt DateTime @default(now()),
    @after {create syncDealToHubSpot @async}
}

record LeadSyncResult {
    success Boolean,
    leadsCount Int,
    message String
}

record DealCreationResult {
    success Boolean,
    dealId String @optional,
    hubspotDealId String @optional,
    message String
}

record LeadScoreResult {
    leadId UUID,
    score Int,
    factors Map
}

@public event createLeadInHubSpot {
    firstName String,
    lastName String,
    email Email,
    phone String @optional,
    company String @optional,
    jobTitle String @optional,
    leadStatus String @optional,
    lifecycleStage String @optional
}

@public event createDealInHubSpot {
    dealName String,
    dealStage String @optional,
    amount String @optional,
    closeDate String @optional,
    priority String @optional,
    associatedLeadEmail Email @optional
}

@public workflow createLeadInHubSpot {
    {Lead {
        firstName createLeadInHubSpot.firstName,
        lastName createLeadInHubSpot.lastName,
        email createLeadInHubSpot.email,
        phone createLeadInHubSpot.phone,
        company createLeadInHubSpot.company,
        jobTitle createLeadInHubSpot.jobTitle,
        leadStatus createLeadInHubSpot.leadStatus,
        lifecycleStage createLeadInHubSpot.lifecycleStage
    }} @as [localLead];

    {hubspot/Contact {
        first_name createLeadInHubSpot.firstName,
        last_name createLeadInHubSpot.lastName,
        email createLeadInHubSpot.email,
        job_title createLeadInHubSpot.jobTitle,
        lead_status createLeadInHubSpot.leadStatus,
        lifecycle_stage createLeadInHubSpot.lifecycleStage
    }} @as [hubspotContact];

    "#js `
        const lead = localLead[0];
        const contact = hubspotContact[0];
        ({
            id: lead.id,
            hubspotId: contact.id
        })
    `" @as updateData;

    {Lead {
        id? updateData.id,
        hubspotId updateData.hubspotId
    }} @as [updatedLead];

    updatedLead
}

@public workflow createDealInHubSpot {
    {hubspot/Deal {
        deal_name createDealInHubSpot.dealName,
        deal_stage createDealInHubSpot.dealStage,
        amount createDealInHubSpot.amount,
        close_date createDealInHubSpot.closeDate,
        priority createDealInHubSpot.priority
    }} @as [hubspotDeal];

    "#js `
        const hsDeal = hubspotDeal[0];
        ({
            dealName: createDealInHubSpot.dealName,
            dealStage: createDealInHubSpot.dealStage || 'prospecting',
            amount: parseFloat(createDealInHubSpot.amount || '0'),
            priority: createDealInHubSpot.priority || 'medium',
            hubspotId: hsDeal.id
        })
    `" @as dealData;

    {Deal dealData} @as [localDeal];

    "#js `
        const deal = localDeal[0];
        ({
            success: true,
            dealId: deal.id,
            hubspotDealId: deal.hubspotId,
            message: 'Deal created successfully in HubSpot and local database'
        })
    `" @as result;

    {DealCreationResult result}
}

workflow syncLeadToHubSpot {
    "Auto-syncing Lead to HubSpot: " + this.email @as logMessage;
    console.log(logMessage);

    {hubspot/Contact {
        first_name this.firstName,
        last_name this.lastName,
        email this.email,
        job_title this.jobTitle,
        lead_status this.leadStatus,
        lifecycle_stage this.lifecycleStage
    }} @as [hubspotContact];

    "#js `
        const contact = hubspotContact[0];
        contact ? contact.id : null
    `" @as hsId;

    {Lead {
        id? this.id,
        hubspotId hsId
    }} @as [updatedLead];

    "Lead synced to HubSpot with ID: " + hsId @as successMessage;
    console.log(successMessage);

    updatedLead
}

workflow syncDealToHubSpot {
    "Auto-syncing Deal to HubSpot: " + this.dealName @as logMessage;
    console.log(logMessage);

    "#js `
        this.amount ? this.amount.toString() : '0'
    `" @as amountStr;

    "#js `
        this.closeDate ? this.closeDate.toISOString().split('T')[0] : null
    `" @as closeDateStr;

    {hubspot/Deal {
        deal_name this.dealName,
        deal_stage this.dealStage,
        amount amountStr,
        close_date closeDateStr,
        priority this.priority
    }} @as [hubspotDeal];

    "#js `
        const deal = hubspotDeal[0];
        deal ? deal.id : null
    `" @as hsId;

    {Deal {
        id? this.id,
        hubspotId hsId
    }} @as [updatedDeal];

    "Deal synced to HubSpot with ID: " + hsId @as successMessage;
    console.log(successMessage);

    updatedDeal
}

@public agent salesAssistant {
    llm "default",
    role "You are a sales automation assistant for managing HubSpot CRM.",
    instruction "You help with sales operations including:

    1. Creating new leads in HubSpot - use createLeadInHubSpot
    2. Syncing leads from HubSpot to local database - use syncLeadsFromHubSpot
    3. Creating deals in HubSpot - use createDealInHubSpot
    4. Scoring leads based on their attributes - use scoreLeads
    5. Retrieving lead information - use getLeadById or getAllLeads

    When asked to create a lead, ensure you have:
    - First name (required)
    - Last name (required)
    - Email (required)
    - Optional: phone, company, job title, lead status, lifecycle stage

    When creating deals, ask for:
    - Deal name (required)
    - Optional: deal stage, amount, close date, priority

    Be helpful and proactive in suggesting next steps for sales workflows.",

    tools [
        simpleSales.core/createLeadInHubSpot,
        simpleSales.core/syncLeadsFromHubSpot,
        simpleSales.core/createDealInHubSpot,
        hubspot/Contact,
        hubspot/Deal
    ]
}

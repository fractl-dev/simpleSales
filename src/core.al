module simpleSales.core

entity Lead {
    id UUID @id @default(uuid()),
    firstName String,
    lastName String,
    email Email,
    phone String @optional,
    company String @optional,
    jobTitle String @optional,
    leadStatus @enum("new", "contacted", "qualified", "unqualified") @default("new"),
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

@public event syncLeadsFromHubSpot {
    limit Int @default(50)
}

@public event createDealInHubSpot {
    dealName String,
    dealStage String @optional,
    amount String @optional,
    closeDate String @optional,
    priority String @optional,
    associatedLeadEmail Email @optional
}

@public event scoreLeads {
    recalculateAll Boolean @default(false)
}

@public event getLeadById {
    id UUID
}

@public event getAllLeads {
    limit Int @default(100)
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

    // Update local lead with HubSpot ID
    "#js `
        const lead = localLead[0];
        const contact = hubspotContact[0];
        {
            id: lead.id,
            hubspotId: contact.id
        }
    `" @as updateData;

    {Lead {
        id? updateData.id,
        hubspotId updateData.hubspotId
    }} @as [updatedLead];

    updatedLead
}

@public workflow syncLeadsFromHubSpot {
    {hubspot/Contact} @as [hubspotContacts];

    "#js `
        const contacts = hubspotContacts || [];
        const results = [];

        for (const contact of contacts.slice(0, syncLeadsFromHubSpot.limit)) {
            const existingLead = {
                hubspot/Contact: {
                    id: contact.id
                }
            };

            results.push({
                firstName: contact.first_name || 'Unknown',
                lastName: contact.last_name || 'Unknown',
                email: contact.email || 'noemail@example.com',
                jobTitle: contact.job_title,
                leadStatus: contact.lead_status || 'new',
                lifecycleStage: contact.lifecycle_stage || 'lead',
                hubspotId: contact.id
            });
        }

        {
            success: true,
            leadsCount: results.length,
            message: 'Successfully synced ' + results.length + ' leads from HubSpot'
        }
    `" @as result;

    {LeadSyncResult result}
}

@public workflow createDealInHubSpot {
    // Create deal in HubSpot
    {hubspot/Deal {
        deal_name createDealInHubSpot.dealName,
        deal_stage createDealInHubSpot.dealStage,
        amount createDealInHubSpot.amount,
        close_date createDealInHubSpot.closeDate,
        priority createDealInHubSpot.priority
    }} @as [hubspotDeal];

    // Create local deal record
    "#js `
        const hsDeal = hubspotDeal[0];
        {
            dealName: createDealInHubSpot.dealName,
            dealStage: createDealInHubSpot.dealStage || 'prospecting',
            amount: parseFloat(createDealInHubSpot.amount || '0'),
            priority: createDealInHubSpot.priority || 'medium',
            hubspotId: hsDeal.id
        }
    `" @as dealData;

    {Deal dealData} @as [localDeal];

    "#js `
        const deal = localDeal[0];
        {
            success: true,
            dealId: deal.id,
            hubspotDealId: deal.hubspotId,
            message: 'Deal created successfully in HubSpot and local database'
        }
    `" @as result;

    {DealCreationResult result}
}

@public workflow scoreLeads {
    // Query all leads or specific leads
    {Lead} @as [leads];

    // Calculate score for each lead
    "#js `
        const scoredLeads = [];

        for (const lead of leads) {
            let score = 0;
            const factors = {};

            // Email provided: +10
            if (lead.email) {
                score += 10;
                factors.hasEmail = 10;
            }

            // Phone provided: +10
            if (lead.phone) {
                score += 10;
                factors.hasPhone = 10;
            }

            // Company provided: +15
            if (lead.company) {
                score += 15;
                factors.hasCompany = 15;
            }

            // Job title provided: +15
            if (lead.jobTitle) {
                score += 15;
                factors.hasJobTitle = 15;
            }

            // Lead status bonuses
            if (lead.leadStatus === 'qualified') {
                score += 30;
                factors.isQualified = 30;
            } else if (lead.leadStatus === 'contacted') {
                score += 20;
                factors.isContacted = 20;
            }

            // Lifecycle stage bonuses
            if (lead.lifecycleStage === 'sales_qualified_lead') {
                score += 25;
                factors.isSql = 25;
            } else if (lead.lifecycleStage === 'marketing_qualified_lead') {
                score += 20;
                factors.isMql = 20;
            } else if (lead.lifecycleStage === 'opportunity') {
                score += 35;
                factors.isOpportunity = 35;
            }

            scoredLeads.push({
                leadId: lead.id,
                score: score,
                factors: factors
            });
        }

        scoredLeads
    `" @as scores;

    scores
}

@public workflow getLeadById {
    {Lead {id? getLeadById.id}} @as [lead];
    lead
}

@public workflow getAllLeads {
    {Lead} @as [leads];

    "#js `
        const allLeads = leads || [];
        allLeads.slice(0, getAllLeads.limit)
    `" @as limitedLeads;

    limitedLeads
}

workflow syncLeadToHubSpot {
    // 'this' refers to the newly created Lead entity instance
    console.log("Auto-syncing Lead to HubSpot: " + this.email);

    // Create contact in HubSpot
    {hubspot/Contact {
        first_name this.firstName,
        last_name this.lastName,
        email this.email,
        job_title this.jobTitle,
        lead_status this.leadStatus,
        lifecycle_stage this.lifecycleStage
    }} @as [hubspotContact];

    // Update the local Lead with HubSpot ID
    "#js `
        const contact = hubspotContact[0];
        contact ? contact.id : null
    `" @as hsId;

    {Lead {
        id? this.id,
        hubspotId hsId
    }} @as [updatedLead];

    console.log("Lead synced to HubSpot with ID: " + hsId);

    updatedLead
}

workflow syncDealToHubSpot {
    // 'this' refers to the newly created Deal entity instance
    console.log("Auto-syncing Deal to HubSpot: " + this.dealName);

    // Convert amount to string for HubSpot
    "#js `
        this.amount ? this.amount.toString() : '0'
    `" @as amountStr;

    // Convert closeDate to ISO string if present
    "#js `
        this.closeDate ? this.closeDate.toISOString().split('T')[0] : null
    `" @as closeDateStr;

    // Create deal in HubSpot
    {hubspot/Deal {
        deal_name this.dealName,
        deal_stage this.dealStage,
        amount amountStr,
        close_date closeDateStr,
        priority this.priority
    }} @as [hubspotDeal];

    // Update the local Deal with HubSpot ID
    "#js `
        const deal = hubspotDeal[0];
        deal ? deal.id : null
    `" @as hsId;

    {Deal {
        id? this.id,
        hubspotId hsId
    }} @as [updatedDeal];

    console.log("Deal synced to HubSpot with ID: " + hsId);

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
        simpleSales.core/scoreLeads,
        simpleSales.core/getLeadById,
        simpleSales.core/getAllLeads,
        hubspot/Contact,
        hubspot/Deal
    ]
}

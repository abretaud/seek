var Wizards = {};

Wizards.Wizard = function (element) {
    this.steps = [];
    this.currentStep = nil;
    this.element = element;
    var wizard = this;
    $j('[data-role="seek-wizard-step"]', this.element).each(function (index, stepElement) {
        wizard.steps.push(new Wizards.Step(index + 1, $j(stepElement), wizard));
    });

    this.element.prepend(HandlebarsTemplates['wizard/nav']({ steps: wizard.steps }));
    this.element.append(HandlebarsTemplates['wizard/buttons']());
    $j('[data-role="seek-wizard-nav"] li a', this.element).click(function () {
        wizard.gotoStep($j(this).data('step'));
        return false;
    });
    $j('[data-role="seek-wizard-prev-btn"]', this.element).click(function () {
        wizard.lastStep();
    });

    $j('[data-role="seek-wizard-next-btn"]', this.element).click(function () {
        wizard.nextStep();
    });

    this.gotoStep(1);
};

Wizards.Wizard.prototype.step = function (number) {
    return this.steps[number - 1];
};

Wizards.Wizard.prototype.gotoStep = function (number) {
    for(var i = 0; i < this.steps.length; i++)
        this.steps[i].deactivate();

    if(this.step(number)) {
        this.currentStep = this.step(number);
        this.step(number).activate();
        this.updateNav();
        return true;
    } else
        return false;
};
Wizards.Wizard.prototype.nextStep = function () {
    var next = this.currentStep.number + 1;

    if(next > this.steps.length)
        return false;

    this.gotoStep(next)
};
Wizards.Wizard.prototype.lastStep = function () {
    var last = this.currentStep.number - 1;

    if(last < 1)
        return false;

    this.gotoStep(last)
};
Wizards.Wizard.prototype.updateNav = function () {
    // Highlight breadcrumb
    $j('[data-role="seek-wizard-nav"] li', this.element).removeClass('active');
    $j('[data-role="seek-wizard-nav"] li a[data-step="'+this.currentStep.number+'"]', this.element).parent().addClass('active');

    // Show hide next/prev buttons
    if(this.currentStep.number == 1)
        $j('[data-role="seek-wizard-prev-btn"]', this.element).hide();
    else
        $j('[data-role="seek-wizard-prev-btn"]', this.element).show();

    if(this.currentStep.number == this.steps.length)
        $j('[data-role="seek-wizard-next-btn"]', this.element).hide();
    else
        $j('[data-role="seek-wizard-next-btn"]', this.element).show();
};

Wizards.Step = function (number, element, wizard) {
    this.number = number;
    this.unlocked = false;
    this.wizard = wizard;
    this.element = element;
    this.name = this.element.data('stepName');
};

Wizards.Step.prototype.unlock = function () { this.unlocked = false; };
Wizards.Step.prototype.lock = function () { this.deactivate(); this.unlocked = true; };
Wizards.Step.prototype.activate = function () { this.unlock(); this.element.show(); };
Wizards.Step.prototype.deactivate = function () { this.element.hide(); };

$j(document).ready(function () {
    $j('[data-role="seek-wizard"]').each(function (index, wizard) {
        this.wizard = new Wizards.Wizard($j(this));
    });
});

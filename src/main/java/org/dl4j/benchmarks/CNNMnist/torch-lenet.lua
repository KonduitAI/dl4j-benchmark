-- Torch7 Lenet
--
-- Reference: https://github.com/torch/demos/blob/master/train-a-digit-classifier/train-on-mnist.lua

require 'torch'
require 'nn'
require 'optim'
--require 'src/main/resources/torch-data/dataset-mnist'
mnist = require 'mnist' -- alternative but was giving bad results
require 'src/main/java/org/dl4j/benchmarks/Utils/benchmark-util'

total_time = sys.clock()
torch.manualSeed(42)

-- epoch tracker
opt = {
    gpu = false,
    usecuDNN = true,
    max_epoch = 11,
    numExamples = 1000 , -- numExamples
    numTestExamples = 10000,
    batchSize = 66,
    testBatchSize = 100,
    noutputs = 10,
    channels = 1,
    height = 28,
    width = 28,
    ninputs = 28*28,
    coefL2 = 5e-4,
    nGPU = 4,
    learningRate = 1e-2,
    weightDecay = opt.coefL2,
    nesterov = true,
    momentum =  0.9,
    dampening = 0
}

optimState = {
    learningRate = opt.learningRate,
    weightDecay = opt.weightDecay,
    nesterov = opt.nesterov,
    momentum =  opt.momentum,
    dampening = opt.dampening
}

classes = {'1','2','3','4','5','6','7','8','9','10'}
geometry = {opt.height, opt.width}


------------------------------------------------------------
-- print('Load data')
data_load_time = sys.clock()
--trainData = mnist.loadTrainSet(opt.numExamples, geometry)
--trainData:normalizeGlobal()
--
--testData = mnist.loadTestSet(opt.numTestExamples, geometry)
--testData:normalizeGlobal()

data_load_time = sys.clock() - data_load_time

trainData = mnist.traindataset()
testData = mnist.testdataset()


------------------------------------------------------------
--print('Build model')
model = nn.Sequential()
-- stage 1 : mean suppresion -> filter bank -> squashing -> max pooling
model:add(nn.SpatialConvolutionMM(1, 20, 5, 5))
model:add(nn.Identity())
model:add(nn.SpatialMaxPooling(2, 2, 2, 2))
-- stage 2 : mean suppresion -> filter bank -> squashing -> max pooling
model:add(nn.SpatialConvolutionMM(20, 50, 5, 5))
model:add(nn.Identity())
model:add(nn.SpatialMaxPooling(2, 2, 2, 2))
-- stage 3 : standard 2-layer MLP:
--model:add(nn.Reshape(50*5*5))
--model:add(nn.Linear(50*5*5, 500))
model:add(nn.Reshape(50*4*4))
model:add(nn.Linear(50*4*4, 500))

model:add(nn.ReLU())
model:add(nn.Linear(500, #classes))
model:add(nn.LogSoftMax())
--model:add(util.cast(nn.Copy('torch.FloatTensor', torch.type(util.cast(torch.Tensor(), opt.gpu)))), opt.gpu)
--model:add(util.cast(model, opt.gpu))

if(opt.gpu) then
    require 'cunn'
    model:cuda()
    model = util.convertCuda(model, opt.usecuDNN)
end

-- TODO put this in util
for i=1, #model.modules do
    method = util.w_init_xavier_caffe
    local m = model.modules[i]
    if m.__typename == 'nn.SpatialConvolutionMM' then
        m:reset(method(m.nInputPlane*m.kH*m.kW, m.nOutputPlane*m.kH*m.kW))
        m.bias = nil
        m.gradBias = nil
    elseif m.__typename == 'nn.Linear' then
        m:reset(method(m.weight:size(2), m.weight:size(1)))
        m.bias:zero()
    end
end

--flattens & creates views for optim to process param and gradients
parameters,gradParameters = model:getParameters()

criterion = opt.gpu and nn.ClassNLLCriterion():cuda() or nn.ClassNLLCriterion()

--print(model)

------------------------------------------------------------
--print('Train model')

function train(dataset)
    model:training()

--    loops from 1 to full dataset size by batchsize
    for t = 1,opt.numExamples,opt.batchSize do
        -- create mini batch
        local inputs = opt.gpu and torch.CudaTensor(opt.batchSize,1,28,2) or torch.Tensor(opt.batchSize,1,28,28)
        local targets = opt.gpu and torch.CudaTensor(opt.batchSize):zero() or torch.zeros(opt.batchSize)
        local k = 1
--        for i = t,math.min(t+opt.batchSize-1,dataset:size()) do
--            -- load new sample
--            local sample = dataset[i]
--            local input = sample[1]:clone():resize(opt.channels,opt.height,opt.width)
--            local _,target = sample[2]:clone():max(1)
--            target = target:squeeze()
--            inputs[k] = input
--            targets[k] = target
--            k = k + 1
--        end
        for i = t,math.min(t+opt.batchSize-1,dataset.size) do
            local sample = dataset[i]
            local input = sample.x:clone()
            local target = sample.y+1
            inputs[k] = input
            if target <= 0 then
                target = 1
            end
            targets[k] = target
            k = k + 1
        end

        inputs = opt.gpu and inputs:cuda() or inputs
        -- create closure to evaluate f(X) and df/dX
        local feval = function(x)
            -- just in case:
            collectgarbage()

            -- get new parameters
            if x ~= parameters then parameters:copy(x) end

            -- reset gradients
            gradParameters:zero()

            -- evaluate function for complete mini batch
            local outputs = model:forward(inputs)
            local loss = criterion:forward(outputs, targets)

            -- estimate df/dW
            local df_do = criterion:backward(outputs, targets)
            model:backward(inputs, df_do)

            return f, gradParameters
        end

        optim.sgd(feval,parameters,optimState)
    end

end

------------------------------------------------------------
--print('Evaluate')

-- this matrix records the current confusion across classes
confusion = optim.ConfusionMatrix(classes)

function test(dataset)
    model:evaluate()
    -- test over given dataset
--    for t = 1,dataset:size(),opt.testBatchSize do
--        -- disp progress
--        xlua.progress(t, dataset:size())
--
--        -- create mini batch
--        local inputs = torch.Tensor(opt.batchSize,opt.channels,opt.height,opt.width)
--        local targets = torch.Tensor(opt.testBatchSize)
--        local k = 1
--        for i = t,math.min(t+opt.testBatchSize-1,opt.numTestExamples) do
--            -- load new sample
--            local sample = dataset[i]
--            local input = sample[1]:clone():resize(opt.channels,opt.height,opt.width)
--            local _,target = sample[2]:clone():max(1)
--            target = target:squeeze()
--            inputs[k] = input
--            targets[k] = target
--            k = k + 1
--        end
    for t=1,dataset.size,opt.batchSize do

        -- create mini batch
        local inputs = torch.Tensor(opt.testBatchSize,1,geometry[1],geometry[2])
        local targets = torch.Tensor(opt.testBatchSize)
        local k = 1
        for i = t,math.min(t+opt.testBatchSize-1,dataset.size) do
            local sample = dataset[i]
            local input = sample.x:clone()
            local target = sample.y+1
            if target <=0 then
                target = 1
            end
            inputs[k] = input
            targets[k] = target
            k = k + 1
        end

        -- test samples
        local preds = model:forward(inputs)

        -- confusion:
        confusion:batchAdd(preds, targets)
    end

    -- print confusion matrix
    confusion:updateValids()
    print(confusion)
    print('Accuracy: ', confusion.totalValid * 100)
    confusion:zero()
end

train_time = sys.clock()
for _ = 1,opt.max_epoch do
    train(trainData)
end
train_time = sys.clock() - train_time

test_time = sys.clock()
test(testData)
test_time = sys.clock() - test_time
total_time = sys.clock() - total_time

print("****************Example finished********************")
util.printTime('Data load', data_load_time)
util.printTime('Train', train_time)
util.printTime('Test', test_time)
util.printTime('Total', total_time)